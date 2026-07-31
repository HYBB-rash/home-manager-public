# NixOS and Home Manager configuration

This branch is generated from a private daily configuration. Its Git history is
independent, and machine-specific or personally identifying values are replaced
with explicit placeholders before publication.

Before using it:

1. replace `user`, `/home/user`, `example-user`, and `example.invalid` values;
2. replace every `REPLACE-ME` disk UUID with values from your own generated
   hardware configuration;
3. replace the placeholder SSH public keys and Thunderbird profile path;
4. run `nix flake check` before activation.

The private source's local PicACG input is intentionally omitted from this
branch. Add your own optional local packages only after configuring a source
that is safe and available on your machine.

Do not commit credentials or machine identifiers. The private source repository
uses a blocking export scan and publishes this branch only when that scan passes.
