# Imported Epic Games references

## Linter

- Repository: https://github.com/EpicGames/Linter
- Commit: 65e0fdd258b0dc354388d1d9abce39e0e27d16db
- License: MIT
- Imported files:
  - LICENSE
  - docs/unrealguidelines.md

The imported guideline document is used as an audit requirements reference.
The UE4.26 plugin code and cooked assets are intentionally excluded.

## CommandletPlugin

- Repository: https://github.com/EpicGames/CommandletPlugin
- Commit: f532bd5a83e4f3a6c9593789500745b5a0827a28
- License: BSD 3-Clause
- Imported files:
  - LICENSE
  - CommandletPlugin.uplugin
  - Source/CommandletPlugin/CommandletPlugin.Build.cs
  - Source/CommandletPlugin/Private/CommandletPluginModule.cpp
  - Source/CommandletPlugin/Private/CommandletPluginPrivate.h
  - Source/CommandletPlugin/Private/Commandlets/HelloWorldCommandlet.cpp
  - Source/CommandletPlugin/Private/Commandlets/HelloWorldCommandlet.h

This is reference code, not an enabled project plugin. The original example
was built for UE4.19 and must be ported before use with UE5.5.4.

The upstream usage guide remains available at
https://github.com/EpicGames/CommandletPlugin/blob/f532bd5a83e4f3a6c9593789500745b5a0827a28/README.md.
