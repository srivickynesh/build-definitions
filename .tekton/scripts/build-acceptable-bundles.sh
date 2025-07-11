#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# helps with debugging
DATA_BUNDLE_REPO="${DATA_BUNDLE_REPO:-quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles}"
mapfile -t BUNDLES < <(cat "$@")

pr_number=$(gh search prs --repo konflux-ci/build-definitions --merged "${REVISION}" --json number --jq '.[].number')

# changed files in a PR
mapfile -t changed_files < <(gh pr view "https://github.com/konflux-ci/build-definitions/pull/${pr_number}" --json files --jq '.files.[].path')
# store a list of changed task files
task_records=()
# loop over all changed files
for path in "${changed_files[@]}"; do
    # check that the file modified is the task file
    if [[ "${path}" == task/*/*/*.yaml ]]; then
        IFS='/' read -r -a path_array <<< "${path}"
        dir_name_after_task="${path_array[1]}"
        file_name=$(basename "${path_array[-1]}" ".yaml")

        if [[ "${dir_name_after_task}" == "${file_name}" ]]; then
            # GIT_URL is the repo_url from PAC (https://hostname/org/repo)
            task_records+=("git+${GIT_URL}.git//${path}@${REVISION}")
        fi
    fi
done

echo "Tasks to be added:"
printf '%s\n' "${task_records[@]}"

echo "Bundles to be added:"
printf '%s\n' "${BUNDLES[@]}"

if [[ -z ${task_records[*]} && -z ${BUNDLES[*]} ]]; then
    echo Nothing to do...
    exit 0
fi

# The OPA data bundle is tagged with the current timestamp. This has two main
# advantages. First, it prevents the image from accidentally not having any tags,
# and getting garbage collected. Second, it helps us create a timeline of the
# changes done to the data over time.
DATA_BUNDLE_TAG=${DATA_BUNDLE_TAG:-$(date '+%s')}

# task_records can be empty if a task wasn't changed
TASK_PARAM=()
if [ ${#task_records[@]} -gt 0 ]; then
  mapfile -t -d ' ' TASK_PARAM < <(printf -- '--git=%s ' "${task_records[@]}")
fi
mapfile -t -d ' ' BUNDLES_PARAM < <(printf -- '--bundle=%s ' "${BUNDLES[@]}")

PARAMS=("${TASK_PARAM[@]}" "${BUNDLES_PARAM[@]}")

ec track bundle --debug \
    --in-effect-days 60 \
    --input "oci:${DATA_BUNDLE_REPO}:latest" \
    --output "oci:${DATA_BUNDLE_REPO}:${DATA_BUNDLE_TAG}" \
    --timeout "15m0s" \
    --freshen \
    --prune \
    "${PARAMS[@]}"

# To facilitate usage in some contexts, tag the image with the floating "latest" tag.
skopeo copy "docker://${DATA_BUNDLE_REPO}:${DATA_BUNDLE_TAG}" "docker://${DATA_BUNDLE_REPO}:latest"
