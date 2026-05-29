```@meta
CurrentModule = BiTemporalData
```

# [Reference](@id reference)

## Index

```@index
Pages = ["reference.md"]
```

## Operations

`insert!` and `diff` extend `Base` functions, so they are documented explicitly
here; the remaining operations and types are listed below.

```@docs
insert!(::BitemporalStore, ::Any, ::Any)
diff(::BitemporalStore)
```

```@autodocs
Modules = [BiTemporalData]
```
