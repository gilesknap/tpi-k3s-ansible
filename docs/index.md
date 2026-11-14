---
html_theme.sidebar_secondary.remove: true
---

```{include} ../README.md
:end-before: <!-- README only content
```

:::{tip}
New here? Start with the {doc}`architecture overview <explanations/architecture>`:
the whole cluster on one page, with diagrams, and links to a page for each layer.
:::

## Documentation

::::{grid} 2
:gutter: 4

:::{grid-item-card} {material-regular}`directions_walk;2em`
```{toctree}
:maxdepth: 2
tutorials
```
+++
Tour the running cluster, or build it from bare metal.
:::

:::{grid-item-card} {material-regular}`directions;2em`
```{toctree}
:maxdepth: 2
how-to
```
+++
Runbooks for operating it.
:::

:::{grid-item-card} {material-regular}`info;2em`
```{toctree}
:maxdepth: 2
explanations
```
+++
Architecture, with diagrams, and the reasons behind it.
:::

:::{grid-item-card} {material-regular}`menu_book;2em`
```{toctree}
:maxdepth: 2
reference
```
+++
Services, inventory, variables, commands.
:::

::::
