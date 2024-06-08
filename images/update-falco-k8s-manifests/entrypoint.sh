#!/usr/bin/env bash
#
# Copyright (C) 2022 The Falco Authors.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

# Args from environment (with defaults)
GH_PROXY="${GH_PROXY:-"http://ghproxy"}"
GH_ORG="${GH_ORG:-"falcosecurity"}"
GH_REPO="${GH_REPO:-"deploy-kubernetes"}"
BOT_NAME="${BOT_NAME:-"poiana"}"
BOT_MAIL="${BOT_MAIL:-"51138685+poiana@users.noreply.github.com"}"
BOT_GPG_KEY_PATH="${BOT_GPG_KEY_PATH:-"/root/gpg-signing-key/poiana.asc"}"
BOT_GPG_PUBLIC_KEY="${BOT_GPG_PUBLIC_KEY:-"EC9875C7B990D55F3B44D6E45F284448FF941C8F"}"
HELM_CHART_NAME="${HELM_CHART_NAME:-"falco"}"

export GIT_COMMITTER_NAME=${BOT_NAME}
export GIT_COMMITTER_EMAIL=${BOT_MAIL}
export GIT_AUTHOR_NAME=${BOT_NAME}
export GIT_AUTHOR_EMAIL=${BOT_MAIL}

# Generate template files with helm, otherwise errors out.
# $1: output directory
# $2: chart name
generate_deployment_files() {
    local chart_name="${2}"

    echo "> configuring helm"
    helm repo add falcosecurity https://falcosecurity.github.io/charts
    helm repo update

    echo "> generating template files"
    # inspired by https://github.com/helm/helm/issues/4680#issuecomment-613201032
    helm template --skip-tests --dry-run \
      "${chart_name}" "falcosecurity/${chart_name}" \
      | awk -vout=$1 -F": " '
        $0~/^# Source: / {
            file=out"/"$2;
            if (!(file in filemap)) {
                filemap[file] = 1
                print "Creating "file;
                system ("mkdir -p $(dirname "file"); echo -n "" > "file);
            }
        }
        $0!~/^#/ {
            if (file) {
                print $0 >> file;
            }
        }' && \
        { pushd ${1}/${chart_name} && \
          rm -f kustomization.yaml && kustomize create --autodetect --recursive && \
          popd ; } && \
        return 0
    echo "ERROR: Unable to generate deployment files from helm template" >&2
    return 1
}

# Sets git user configs, otherwise errors out.
# $1: git user name
# $2: git user email
ensure_git_config() {
    echo "> configuring git user (name=$1, email=$2)..." >&2
    git config --global user.name "$1"
    git config --global user.email "$2"

    git config user.name &>/dev/null && git config user.email &>/dev/null && return 0
    echo "ERROR: git config user.name, user.email unset. No defaults provided" >&2
    return 1
}

# Configures GPG key, otherwise errors out.
# $1: GPG key location
# $2: GPG ASCII armored public key
ensure_gpg_key() {
    echo "> configuring git with gpg key=$1..." >&2
    gpg --import "$1"
    git config --global commit.gpgsign true
    git config --global user.signingkey "$2"

    git config --global commit.gpgsign &>/dev/null && git config --global user.signingkey &>/dev/null && return 0
    echo "ERROR: git gpg key location, public key ID unset. No defaults provided" >&2
    return 1
}

# Creates a pull-request in case there are changes to commit and to push.
# $1: path of the file containing the token
create_pr() {
    nchanges=$(git status --porcelain=v1 2> /dev/null | wc -l)
    if [ "${nchanges}" -eq "0" ]; then
        echo "> moving on since there are no changes..." >&2
        return 0;
    fi

    echo "> creating commit..." >&2
    title="update(kubernetes): Deployment files"
    git add .
    git commit -s -m "${title}"

    user=$(get_user_from_token "$1")
    branch="update/falco-k8s-manifests-${GH_ORG}"
    echo "> pushing commit as ${user} on branch ${branch}..." >&2
    git push -f \
        "https://${user}:$(cat "$1")@github.com/${GH_ORG}/${GH_REPO}" \
        "HEAD:${branch}"

    echo "> creating pull-request to merge ${user}:${branch} into main..." >&2
    body='Updating deployment files (automatically generated by helm template). Made using the [update-falco-k8s-manifests](https://github.com/diginfra/test-infra/blob/main/config/jobs/update-falco-k8s-manifests/update-falco-k8s-manifests.yaml) ProwJob. Do not edit this PR.\n\n/kind update\n\n/area manifests'

    pr-creator \
        --github-endpoint="${GH_PROXY}" \
        --github-token-path="$1" \
        --org="${GH_ORG}" --repo="${GH_REPO}" --branch=main \
        --title="${title}" --match-title="${title}" \
        --body="${body}" \
        --local --source="${branch}" \
        --allow-mods --confirm
}

# $1: path of the file containing the token
get_user_from_token() {
    curl --silent -H "Authorization: token $(cat "$1")" "https://api.github.com/user" | grep -Po '"login": "\K.*?(?=")'
}

# $1: the program to check
function check_program {
    if hash "$1" 2>/dev/null; then
        type -P "$1" >&/dev/null
    else
        echo "> aborting because $1 is required..." >&2
       return 1
    fi
}

# Meant to be run in the https://github.com/falcosecurity/deploy-kubernetes repository.
# $1: path of the file containing the token
main() {
    # Checks
    check_program "gpg"
    check_program "git"
    check_program "curl"
    check_program "pr-creator"
    check_program "awk"
    check_program "helm"

    # Settings
    ensure_git_config "${BOT_NAME}" "${BOT_MAIL}"
    ensure_gpg_key "${BOT_GPG_KEY_PATH}" "${BOT_GPG_PUBLIC_KEY}"

    # Generate deployment files
    generate_deployment_files "kubernetes" "${HELM_CHART_NAME}"

    # Create PR (in case there are changes)
    create_pr "$1"
}

if [[ $# -lt 1 ]]; then
    echo "Usage: $(basename "$0") <path to github token>" >&2
    exit 1
fi

main "$@"
