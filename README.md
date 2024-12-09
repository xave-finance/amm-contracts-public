```
██╗  ██╗ █████╗ ██╗   ██╗███████╗     █████╗ ███╗   ███╗███╗   ███╗    ██╗   ██╗██████╗
╚██╗██╔╝██╔══██╗██║   ██║██╔════╝    ██╔══██╗████╗ ████║████╗ ████║    ██║   ██║╚════██╗
 ╚███╔╝ ███████║██║   ██║█████╗      ███████║██╔████╔██║██╔████╔██║    ██║   ██║ █████╔╝
 ██╔██╗ ██╔══██║╚██╗ ██╔╝██╔══╝      ██╔══██║██║╚██╔╝██║██║╚██╔╝██║    ╚██╗ ██╔╝ ╚═══██╗
██╔╝ ██╗██║  ██║ ╚████╔╝ ███████╗    ██║  ██║██║ ╚═╝ ██║██║ ╚═╝ ██║     ╚████╔╝ ██████╔╝
╚═╝  ╚═╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝    ╚═╝  ╚═╝╚═╝     ╚═╝╚═╝     ╚═╝      ╚═══╝  ╚═════╝
```

## Description

This repository contains the smart contracts source code and markets configuration for Xave AMM V3. The repository uses Foundry as the development environment for compilation, testing and deployment tasks.

## Quick Start

```sh
# install forge libraries and dependencies
forge install
forge test
```

Running code coverage reports:

```sh

# note that the SizeTest.t.sol will fail during coverage
# that's because the instrumentation that the coverage
# adds to the code expands the size of the FXPool contract
# making it exceed the 24KB limit
forge coverage

# or you can output an LCOV format report that can
# be read by VSCode plugins like "Coverage Gutters"
forge coverage --report lcov

# if you want to generate html based on the code coverage do the following:
forge coverage --report lcov && genhtml lcov.info --output-dir coverage --branch-coverage && open coverage/index.html

# if you don't have genhtml, on osx you can do this:
brew install lcov
```
