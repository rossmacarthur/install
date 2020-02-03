# Install

This repository just contains a little script that can be downloaded from the
internet to install a Rust crate from a GitHub release. It determines the latest
release, the current platform (without the need for `rustc`), and installs the
extracted binary to the specified location.

## Usage

To install a crate simply run the following

```sh
curl --proto '=https' -fLsS https://rossmacarthur.github.io/install/crate.sh \
    | bash -s -- --repo "<username>/<repository>" --to ~/.cargo/bin
```

or

```sh
wget --no-verbose --https-only https://rossmacarthur.github.io/install/crate.sh \
    | bash -s -- --repo "<username>/<repository>" --to ~/.cargo/bin
```

## Acknowledgements

This script was inspired by the https://github.com/japaric/trust install script.
The platform detection code is taken from
https://github.com/rust-lang/rustup.rs.

## License

This project is licensed under either of

- Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
  http://www.apache.org/licenses/LICENSE-2.0)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
