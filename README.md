# elm-review-common

Provides common linting rules for [`elm-review`](https://package.elm-lang.org/packages/jfmengels/elm-review/latest/).


## Provided rules

- [`NoDeprecated`](https://package.elm-lang.org/packages/jfmengels/elm-review-common/1.2.0/NoDeprecated) - Reports usages of deprecated functions and types.
- [🔧 `NoExposingEverything`](https://package.elm-lang.org/packages/jfmengels/elm-review-common/1.2.0/NoExposingEverything "Provides automatic fixes") - Forbids exporting everything from a module.
- [`NoImportingEverything`](https://package.elm-lang.org/packages/jfmengels/elm-review-common/1.2.0/NoImportingEverything) - Forbids importing everything from a module.
- [`NoMissingTypeAnnotation`](https://package.elm-lang.org/packages/jfmengels/elm-review-common/1.2.0/NoMissingTypeAnnotation) - Reports top-level declarations that do not have a type annotation.
- [`NoMissingTypeAnnotationInLetIn`](https://package.elm-lang.org/packages/jfmengels/elm-review-common/1.2.0/NoMissingTypeAnnotationInLetIn) - Reports `let in` declarations that do not have a type annotation.
- [🔧 `NoMissingTypeExpose`](https://package.elm-lang.org/packages/jfmengels/elm-review-common/1.2.0/NoMissingTypeExpose "Provides automatic fixes") - Reports types that should be exposed but are not.
- [🔧 `NoPrematureLetComputation`](https://package.elm-lang.org/packages/jfmengels/elm-review-common/1.2.0/NoPrematureLetComputation) - Reports let declarations that are computed earlier than needed.


## Configuration

```elm
import NoDeprecated
import NoExposingEverything
import NoImportingEverything
import NoMissingTypeAnnotation
import NoMissingTypeAnnotationInLetIn
import NoMissingTypeExpose
import NoPrematureLetComputation
import Review.Rule exposing (Rule)

config : List Rule
config =
    [ NoExposingEverything.rule
    , NoDeprecated.rule
    , NoImportingEverything.rule []
    , NoMissingTypeAnnotation.rule
    , NoMissingTypeAnnotationInLetIn.rule
    , NoMissingTypeExpose.rule
    , NoPrematureLetComputation.rule
    ]
```

## Try it out

You can try the example configuration above out by running the following command:

```bash
elm-review --template jfmengels/elm-review-common/example
```


## Thanks

Thanks to @sparksp for writing [`NoMissingTypeExpose`](https://package.elm-lang.org/packages/jfmengels/elm-review-common/1.2.0/NoMissingTypeExpose).
