# Polaris Marketplace

**Polaris** is a personal [Claude Code](https://claude.com/claude-code) plugin marketplace: a curated collection of skills, agents, commands, hooks and MCP servers, packaged as independently installable plugins.

## Table of contents

1. [Installation](#installation)
2. [Plugins](#plugins)
3. [Structure](#structure)
4. [Contributing](#contributing)
5. [License](#license)

## Installation <a name="installation"></a>

Inside any Claude Code session:

```
/plugin marketplace add PLeonLopes/polaris-marketplace
```

Then install the plugins you need:

```
/plugin install <plugin-name>@polaris
```

To keep the marketplace up to date:

```
/plugin marketplace update polaris
```

> **Local development:** point Claude Code at a local clone instead — `/plugin marketplace add ./polaris-marketplace`.

## Plugins <a name="plugins"></a>

| Plugin | Description | Contents |
|--------|-------------|----------|
| _none yet_ | — | — |

## Structure <a name="structure"></a>

```
.claude-plugin/marketplace.json   ← registry of all plugins
plugins/<domain>/                 ← one directory per plugin
```

See [AGENTS.md](AGENTS.md) for the full layout and conventions.

## Contributing <a name="contributing"></a>

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License <a name="license"></a>

[MIT](LICENSE)
