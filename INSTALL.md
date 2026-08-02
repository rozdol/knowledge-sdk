# Install knowledge-sdk

`knowledge-sdk` is a standalone Ruby package. It does not require a repository named `knowledge-vault`, an embedded copy inside an Obsidian Vault, or a particular Vault folder structure.

## Requirements

- Ruby 2.6 or newer.
- RubyGems and Bundler for package development.
- The `sqlite3` gem, installed as a runtime dependency, for Structured Dataset commands.

## Install from a source checkout

```sh
git clone <knowledge-sdk-repository-url>
cd knowledge-sdk
bundle install
bundle exec rake test
gem build knowledge-sdk.gemspec
gem install ./knowledge-sdk-14.0.0.gem
kg version
```

The generated gem filename follows `VERSION`. Do not commit built `.gem` artifacts.

During SDK development, run the checkout directly:

```sh
ruby bin/kg version
bundle exec ruby bin/kg help
```

After gem installation, use the `kg` executable from any directory.

## Attach an existing Obsidian Vault

```sh
kg attach /path/to/vault
kg vault list
kg --vault /path/to/vault validate
kg --vault /path/to/vault doctor
```

Attachment writes only to external configuration, which defaults to `~/.knowledge-sdk/config.yml`. It does not write `.vault.yml`, rename the Vault, install an ontology, or modify notes.

You may assign a display name or explicitly opt into a profile:

```sh
kg attach /path/to/vault --name Research
kg --vault /path/to/vault plugin install personal-crm
```

Plugin installation changes the target Vault and is intentionally separate from attachment.

## Create a Vault

Create a minimal ordinary Obsidian Vault:

```sh
kg init /path/to/new-vault
```

Opt into a bundled profile only when its ontology and assets are wanted:

```sh
kg init /path/to/new-vault --profile personal-crm
```

The Vault retains the name and path chosen by its owner.

## Configuration and selection

The default external configuration path is `~/.knowledge-sdk/config.yml`. Override it with `KG_CONFIG` or `--config PATH`.

Vault selection precedence is:

1. `--vault PATH`;
2. `KG_VAULT`;
3. upward discovery from the current directory using `.obsidian` or a registered root;
4. the active attached Vault.

Dataset, audit, and actor overrides are available through `--dataset-db`, `--run-id`, `--actor-id`, `KG_DATASET_DB`, `KG_RUN_ID`, and `KG_ACTOR_ID`. See `docs/Configuration Guide.md` for the external registry format.

## Upgrade

Build and install the newer gem, then inspect and upgrade a selected Vault explicitly:

```sh
gem install ./knowledge-sdk-<version>.gem
kg version
kg --vault /path/to/vault doctor
kg --vault /path/to/vault upgrade
kg --vault /path/to/vault validate
```

Commit or back up a Vault before any migration. Attachment itself is non-mutating; plugin installation, upgrade, migration, and Intent execution may change the selected Vault and should be reviewed in that Vault's own workflow.

## Uninstall

```sh
gem uninstall knowledge-sdk
```

Uninstalling the gem does not delete attached Vaults, external configuration, `.knowledge/` data, or Git history. Remove or retain those user-owned files separately and deliberately.

## Troubleshooting

```sh
kg version
kg vault list
kg --vault /path/to/vault doctor
kg --vault /path/to/vault validate
```

If `kg` is not found after installation, ensure the RubyGems executable directory reported by `gem environment` is on `PATH`. If SQLite cannot load, install a platform-compatible `sqlite3` gem and rerun the command.
