# Migrations

Migration behavior is implemented by `KnowledgeSDK::Migration` and exposed through `kg migrate`. It moves legacy Runtime data to `.knowledge/` and can move embedded SDK/tooling into an external rollback backup before pruning it from a Vault.
