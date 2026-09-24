# Contributing

Work on `dev`. `main` takes a merge from `dev` with `--no-ff`.

Write conventional commits. The commitizen hook rejects a message that does not
follow the format.

Install the hooks in this repository:

```bash
pre-commit install --install-hooks -t pre-commit -t commit-msg -t pre-push
```

Plain `pre-commit install` installs the pre-commit stage alone, and the commit
message and branch hooks then do not run. CI runs the pre-commit stage hooks on
a push and on a pull request.

Every GitHub action is pinned to a commit SHA. Dependabot updates the actions
and the hook revisions weekly against `dev`. `pinact run -u` updates and
re-pins the actions by hand.

## Releases

A release is a merge of `dev` into `main`, then an annotated tag on the merge
and `git push --follow-tags`. The `release` workflow turns every pushed tag into
a GitHub release. GitHub writes its notes: the pull requests merged since the
previous release and a link that compares the two tags.

## Services and their pins

Each service repository is a submodule under `services/<name>`. Work on a
service inside its submodule:

```bash
git -C services/<name> switch dev          # a submodule checks out a commit
# edit, then commit and push in services/<name> as in its own CONTRIBUTING.md
git add services/<name>                    # move the pin here
git commit -m "chore: pin home-server-<name> to <short sha>"
```

A release of this repository pins released services. Tag the service
repository first, check that tag out in `services/<name>`, commit the pin
here, and then release this repository as in "Releases".

## House style

A comment says why, never what. Longer reasoning belongs in the README of the
repository that owns the code. Write the prose in Simplified Technical English:
short sentences, one meaning per word, and the condition before the command.

## Checks in this repository

- Hooks: the basics, shellcheck, ansible-lint and commitizen.
- `.shellcheckrc` lets shellcheck follow `source lib.sh`.
- Ansible variables are `<role>_*`.
- `.github/renovate-image-tags.json` is the Renovate preset that the service
  repositories and this one extend. Here it bumps the digests of the
  `coreos-installer` and `butane` images that `ignition/build.sh` pins.
- A local hook runs `test/test_btrfs_backup.sh` when `btrfs-backup.sh` or the
  test changes. `test/` also holds the VM harness.
