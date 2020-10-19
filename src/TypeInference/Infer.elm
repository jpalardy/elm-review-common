module TypeInference.Infer exposing
    ( InferInternal
    , addProjectVisitors
    , inferType
    , initInternal
    )

import Dict exposing (Dict)
import Elm.Syntax.Declaration as Declaration exposing (Declaration)
import Elm.Syntax.Expression as Expression exposing (Expression)
import Elm.Syntax.Import exposing (Import)
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Pattern as Pattern exposing (Pattern)
import Elm.Syntax.TypeAnnotation as TypeAnnotation exposing (TypeAnnotation)
import Elm.Type
import Review.ModuleNameLookupTable as ModuleNameLookupTable exposing (ModuleNameLookupTable)
import Review.Rule as Rule
import Set exposing (Set)
import TypeInference.TypeByNameLookup as TypeByNameLookup exposing (TypeByNameLookup)


type alias Context a =
    { a
        | moduleNameLookupTable : ModuleNameLookupTable
        , typeByNameLookup : TypeByNameLookup
        , inferInternal : InferInternal
    }


type alias InferInternal =
    { operatorsInScope : Dict String Elm.Type.Type
    }


initInternal : InferInternal
initInternal =
    { operatorsInScope =
        -- TODO Needs access to other dependencies information
        Dict.singleton "+" (Elm.Type.Lambda (Elm.Type.Var "number") (Elm.Type.Lambda (Elm.Type.Var "number") (Elm.Type.Var "number")))
    }


addProjectVisitors : Rule.ProjectRuleSchema { canAddModuleVisitor : (), withModuleContext : Rule.Forbidden } projectContext (Context a) -> Rule.ProjectRuleSchema { canAddModuleVisitor : (), withModuleContext : Rule.Required } projectContext (Context a)
addProjectVisitors schema =
    Rule.withModuleVisitor
        (Rule.withDeclarationListVisitor declarationListVisitor)
        schema



-- IMPORT VISITOR


importVisitor : Node Import -> Context a -> ( List nothing, Context a )
importVisitor node context =
    let
        newContext : Context a
        newContext =
            context
    in
    ( [], newContext )



-- DECLARATION LIST VISITOR


declarationListVisitor : List (Node Declaration) -> Context a -> ( List nothing, Context a )
declarationListVisitor nodes context =
    ( []
    , { context
        | typeByNameLookup =
            TypeByNameLookup.addType
                (List.concatMap typeOfDeclaration nodes)
                context.typeByNameLookup
      }
    )


typeOfDeclaration : Node Declaration -> List ( String, Elm.Type.Type )
typeOfDeclaration node =
    case Node.value node of
        Declaration.FunctionDeclaration function ->
            let
                functionName : String
                functionName =
                    function.declaration
                        |> Node.value
                        |> .name
                        |> Node.value
            in
            case function.signature of
                Just signature ->
                    [ ( functionName
                      , signature
                            |> Node.value
                            |> .typeAnnotation
                            |> typeAnnotationToElmType
                      )
                    ]

                Nothing ->
                    []

        Declaration.CustomTypeDeclaration type_ ->
            let
                customTypeType : Elm.Type.Type
                customTypeType =
                    Elm.Type.Type
                        (Node.value type_.name)
                        (List.map (Node.value >> Elm.Type.Var) type_.generics)
            in
            List.map
                (\(Node _ { name, arguments }) ->
                    let
                        functionType : Elm.Type.Type
                        functionType =
                            List.foldr
                                (\input output ->
                                    Elm.Type.Lambda
                                        (typeAnnotationToElmType input)
                                        output
                                )
                                customTypeType
                                arguments
                    in
                    ( Node.value name, functionType )
                )
                type_.constructors

        Declaration.AliasDeclaration typeAlias ->
            let
                aliasType : Elm.Type.Type
                aliasType =
                    Elm.Type.Type
                        (Node.value typeAlias.name)
                        (List.map (Node.value >> Elm.Type.Var) typeAlias.generics)
            in
            case typeAnnotationToElmType typeAlias.typeAnnotation of
                Elm.Type.Record fields _ ->
                    let
                        functionType : Elm.Type.Type
                        functionType =
                            List.foldr
                                (\( _, type_ ) output -> Elm.Type.Lambda type_ output)
                                aliasType
                                fields
                    in
                    [ ( Node.value typeAlias.name, functionType ) ]

                _ ->
                    []

        Declaration.PortDeclaration { name, typeAnnotation } ->
            [ ( Node.value name, typeAnnotationToElmType typeAnnotation ) ]

        Declaration.InfixDeclaration _ ->
            []

        Declaration.Destructuring _ _ ->
            -- Can't occur
            []



-- TYPE INFERENCE


inferType : Context a -> Node Expression -> Maybe Elm.Type.Type
inferType context node =
    case Node.value node of
        Expression.ParenthesizedExpression expr ->
            inferType context expr

        Expression.Literal _ ->
            -- TODO Re-add "String." but remove it at stringification time
            Just (Elm.Type.Type "String" [])

        Expression.CharLiteral _ ->
            -- TODO Re-add "Char." but remove it at stringification time
            Just (Elm.Type.Type "Char" [])

        Expression.Integer _ ->
            Just (Elm.Type.Var "number")

        Expression.Hex _ ->
            Just (Elm.Type.Var "number")

        Expression.Floatable _ ->
            -- TODO Re-add "Basics." but remove it at stringification time
            Just (Elm.Type.Type "Float" [])

        Expression.UnitExpr ->
            Just (Elm.Type.Tuple [])

        Expression.FunctionOrValue _ name ->
            case ( ModuleNameLookupTable.moduleNameFor context.moduleNameLookupTable node, name ) of
                ( Just [ "Basics" ], "True" ) ->
                    -- TODO Re-add "Basics." but remove it at stringification time
                    Just (Elm.Type.Type "Bool" [])

                ( Just [ "Basics" ], "False" ) ->
                    -- TODO Re-add "Basics." but remove it at stringification time
                    Just (Elm.Type.Type "Bool" [])

                ( Just [], _ ) ->
                    TypeByNameLookup.byName context.typeByNameLookup name

                _ ->
                    Nothing

        Expression.Application elements ->
            case elements of
                [] ->
                    Nothing

                function :: arguments ->
                    inferType context function
                        |> Maybe.andThen (applyArguments context arguments)

        Expression.TupledExpression nodes ->
            let
                inferredTypes : List Elm.Type.Type
                inferredTypes =
                    List.filterMap (inferType context) nodes
            in
            if List.length inferredTypes == List.length nodes then
                Just (Elm.Type.Tuple inferredTypes)

            else
                Nothing

        Expression.ListExpr nodes ->
            if List.isEmpty nodes then
                Just (Elm.Type.Type "List" [ Elm.Type.Var "nothing" ])

            else
                inferTypeFromCombinationOf (List.map (\nodeInList () -> ( context, nodeInList )) nodes)
                    |> Maybe.map (\type_ -> Elm.Type.Type "List" [ type_ ])

        Expression.RecordExpr fields ->
            let
                inferredFields : List ( String, Elm.Type.Type )
                inferredFields =
                    List.filterMap
                        (Node.value
                            >> (\( fieldName, fieldValue ) ->
                                    Maybe.map
                                        (Tuple.pair (Node.value fieldName))
                                        (inferType context fieldValue)
                               )
                        )
                        fields
            in
            if List.length inferredFields == List.length fields then
                Just (Elm.Type.Record inferredFields Nothing)

            else
                Nothing

        Expression.RecordAccess expression (Node _ fieldName) ->
            case inferType context expression of
                Just (Elm.Type.Record fields _) ->
                    find (\( name, _ ) -> fieldName == name) fields
                        |> Maybe.map Tuple.second

                _ ->
                    Nothing

        Expression.RecordAccessFunction fieldName ->
            Just <|
                Elm.Type.Lambda
                    (Elm.Type.Record [ ( String.dropLeft 1 fieldName, Elm.Type.Var "a" ) ] (Just "b"))
                    (Elm.Type.Var "a")

        Expression.OperatorApplication _ _ _ _ ->
            -- TODO Handle this case
            -- Needs lookup to prefix operator
            Nothing

        Expression.IfBlock _ ifTrue ifFalse ->
            inferTypeFromCombinationOf (List.map (\branchNode () -> ( context, branchNode )) [ ifTrue, ifFalse ])

        Expression.PrefixOperator operator ->
            Dict.get operator context.inferInternal.operatorsInScope

        Expression.Operator _ ->
            -- Never occurs
            Nothing

        Expression.Negation expr ->
            inferType context expr

        Expression.LetExpression { declarations, expression } ->
            case inferType context expression of
                Just inferredType ->
                    Just inferredType

                Nothing ->
                    let
                        newContext : Context a
                        newContext =
                            { context
                                | typeByNameLookup =
                                    context.typeByNameLookup
                                        |> TypeByNameLookup.addNewScope
                                        |> TypeByNameLookup.addType (List.concatMap (typeOfLetDeclaration context) declarations)
                            }
                    in
                    inferType newContext expression

        Expression.CaseExpression { expression, cases } ->
            let
                inferredTypeForEvaluatedExpression : Maybe Elm.Type.Type
                inferredTypeForEvaluatedExpression =
                    inferType context expression
            in
            cases
                |> List.map
                    (\( pattern, expr ) () ->
                        let
                            typeByNameLookup : TypeByNameLookup
                            typeByNameLookup =
                                case inferredTypeForEvaluatedExpression of
                                    Just inferred ->
                                        TypeByNameLookup.addType (assignTypeToPattern inferred pattern) context.typeByNameLookup

                                    Nothing ->
                                        case ( Node.value expression, inferTypeFromPattern pattern ) of
                                            ( Expression.FunctionOrValue [] name, Just inferred ) ->
                                                TypeByNameLookup.addType [ ( name, inferred ) ] context.typeByNameLookup

                                            _ ->
                                                context.typeByNameLookup

                            contextToUse : Context a
                            contextToUse =
                                { context | typeByNameLookup = typeByNameLookup }
                        in
                        ( addTypeFromPatternToContext pattern contextToUse
                        , expr
                        )
                    )
                |> inferTypeFromCombinationOf

        Expression.LambdaExpression _ ->
            -- TODO Handle this case
            -- Needs inferring of arguments
            Nothing

        Expression.RecordUpdateExpression name _ ->
            TypeByNameLookup.byName context.typeByNameLookup (Node.value name)

        Expression.GLSLExpression _ ->
            -- TODO Handle this case
            Nothing


addTypeFromPatternToContext : Node Pattern -> Context a -> Context a
addTypeFromPatternToContext pattern context =
    case Node.value pattern of
        Pattern.AllPattern ->
            context

        Pattern.UnitPattern ->
            context

        Pattern.CharPattern _ ->
            context

        Pattern.StringPattern _ ->
            context

        Pattern.IntPattern _ ->
            context

        Pattern.HexPattern _ ->
            context

        Pattern.FloatPattern _ ->
            context

        Pattern.TuplePattern _ ->
            --List.foldl addTypeFromPatternToContext context patterns
            context

        Pattern.RecordPattern _ ->
            context

        Pattern.UnConsPattern _ _ ->
            context

        Pattern.ListPattern _ ->
            context

        Pattern.VarPattern _ ->
            context

        Pattern.NamedPattern { name } argumentPatterns ->
            case TypeByNameLookup.byName context.typeByNameLookup name of
                Just type_ ->
                    let
                        typeVariablesInType : Set String
                        typeVariablesInType =
                            findTypeVariables type_
                    in
                    { context
                        | typeByNameLookup =
                            TypeByNameLookup.addType (assignTypesToPatterns typeVariablesInType type_ argumentPatterns) context.typeByNameLookup
                    }

                Nothing ->
                    context

        Pattern.AsPattern _ _ ->
            context

        Pattern.ParenthesizedPattern _ ->
            context


assignTypesToPatterns : Set String -> Elm.Type.Type -> List (Node Pattern) -> List ( String, Elm.Type.Type )
assignTypesToPatterns typeVariables type_ patterns =
    case patterns of
        [] ->
            []

        head :: rest ->
            case type_ of
                Elm.Type.Lambda input output ->
                    (assignTypeToPattern input head
                        |> List.filter
                            (\( _, typeForPattern ) ->
                                Set.isEmpty <|
                                    Set.intersect
                                        typeVariables
                                        (findTypeVariables typeForPattern)
                            )
                    )
                        ++ assignTypesToPatterns typeVariables output rest

                _ ->
                    []


assignTypeToPattern : Elm.Type.Type -> Node Pattern -> List ( String, Elm.Type.Type )
assignTypeToPattern type_ node =
    case ( Node.value node, type_ ) of
        ( Pattern.VarPattern name, _ ) ->
            [ ( name, type_ ) ]

        ( Pattern.TuplePattern subPatterns, Elm.Type.Tuple tuples ) ->
            List.map2 assignTypeToPattern
                tuples
                subPatterns
                |> List.concat

        ( Pattern.RecordPattern patternFieldNames, Elm.Type.Record typeFields _ ) ->
            List.filterMap
                (Node.value
                    >> (\patternFieldName ->
                            find
                                (\( typeFieldName, _ ) ->
                                    typeFieldName == patternFieldName
                                )
                                typeFields
                       )
                )
                patternFieldNames

        _ ->
            []


inferTypeFromPattern : Node Pattern -> Maybe Elm.Type.Type
inferTypeFromPattern node =
    case Node.value node of
        Pattern.VarPattern _ ->
            Nothing

        Pattern.AllPattern ->
            Nothing

        Pattern.UnitPattern ->
            Just (Elm.Type.Tuple [])

        Pattern.CharPattern _ ->
            Nothing

        Pattern.StringPattern _ ->
            Nothing

        Pattern.IntPattern _ ->
            Nothing

        Pattern.HexPattern _ ->
            Nothing

        Pattern.FloatPattern _ ->
            Nothing

        Pattern.TuplePattern _ ->
            Nothing

        Pattern.RecordPattern _ ->
            Nothing

        Pattern.UnConsPattern _ _ ->
            Nothing

        Pattern.ListPattern _ ->
            Nothing

        Pattern.NamedPattern _ _ ->
            Nothing

        Pattern.AsPattern _ _ ->
            Nothing

        Pattern.ParenthesizedPattern _ ->
            Nothing


inferTypeFromCombinationOf : List (() -> ( Context a, Node Expression )) -> Maybe Elm.Type.Type
inferTypeFromCombinationOf expressions =
    inferTypeFromCombinationOfInternal
        { hasUnknowns = False, maybeInferred = Nothing, typeVariablesList = [] }
        expressions


inferTypeFromCombinationOfInternal :
    { hasUnknowns : Bool
    , maybeInferred : Maybe Elm.Type.Type
    , typeVariablesList : List (Set String)
    }
    -> List (() -> ( Context a, Node Expression ))
    -> Maybe Elm.Type.Type
inferTypeFromCombinationOfInternal previousItemsResult expressions =
    case expressions of
        [] ->
            if previousItemsResult.hasUnknowns then
                Nothing

            else
                case previousItemsResult.typeVariablesList of
                    [] ->
                        -- Should not happen?
                        Nothing

                    head :: tail ->
                        if List.all ((==) head) tail then
                            previousItemsResult.maybeInferred

                        else
                            Nothing

        head :: tail ->
            let
                ( context, node ) =
                    head ()
            in
            case inferType context node of
                Just inferredType ->
                    let
                        typeVariables : Set String
                        typeVariables =
                            findTypeVariables inferredType

                        refinedType_ : Elm.Type.Type
                        refinedType_ =
                            case previousItemsResult.maybeInferred of
                                Just previouslyInferred ->
                                    refineInferredType previouslyInferred inferredType

                                Nothing ->
                                    inferredType
                    in
                    if Set.isEmpty typeVariables then
                        Just inferredType

                    else
                        inferTypeFromCombinationOfInternal
                            { previousItemsResult
                                | maybeInferred = Just refinedType_
                                , typeVariablesList = typeVariables :: previousItemsResult.typeVariablesList
                            }
                            tail

                Nothing ->
                    inferTypeFromCombinationOfInternal
                        { previousItemsResult | hasUnknowns = True }
                        tail


find : (a -> Bool) -> List a -> Maybe a
find predicate list =
    case list of
        [] ->
            Nothing

        head :: tail ->
            if predicate head then
                Just head

            else
                find predicate tail


refineInferredType : Elm.Type.Type -> Elm.Type.Type -> Elm.Type.Type
refineInferredType _ typeB =
    typeB


applyArguments : Context a -> List (Node Expression) -> Elm.Type.Type -> Maybe Elm.Type.Type
applyArguments context arguments type_ =
    applyArgumentsInternal context arguments Set.empty type_


applyArgumentsInternal : Context a -> List (Node Expression) -> Set String -> Elm.Type.Type -> Maybe Elm.Type.Type
applyArgumentsInternal context arguments previousTypeVariables type_ =
    case arguments of
        [] ->
            if Set.intersect (findTypeVariables type_) previousTypeVariables |> Set.isEmpty then
                Just type_

            else
                Nothing

        _ :: restOfArguments ->
            case type_ of
                Elm.Type.Lambda input output ->
                    let
                        typeVariables : Set String
                        typeVariables =
                            Set.union
                                (findTypeVariables input)
                                previousTypeVariables
                    in
                    applyArgumentsInternal context restOfArguments typeVariables output

                _ ->
                    Nothing


findTypeVariables : Elm.Type.Type -> Set String
findTypeVariables type_ =
    case type_ of
        Elm.Type.Var string ->
            Set.singleton string

        Elm.Type.Lambda input output ->
            Set.union
                (findTypeVariables input)
                (findTypeVariables output)

        Elm.Type.Tuple types ->
            types
                |> List.map findTypeVariables
                |> List.foldl Set.union Set.empty

        Elm.Type.Type _ types ->
            types
                |> List.map findTypeVariables
                |> List.foldl Set.union Set.empty

        Elm.Type.Record fields maybeGeneric ->
            let
                startSet : Set String
                startSet =
                    case maybeGeneric of
                        Just generic ->
                            Set.singleton generic

                        Nothing ->
                            Set.empty
            in
            fields
                |> List.map (Tuple.second >> findTypeVariables)
                |> List.foldl Set.union startSet


typeAnnotationToElmType : Node TypeAnnotation -> Elm.Type.Type
typeAnnotationToElmType node =
    case Node.value node of
        TypeAnnotation.GenericType var ->
            Elm.Type.Var var

        TypeAnnotation.Typed (Node _ ( moduleName, name )) nodes ->
            Elm.Type.Type (String.join "." (moduleName ++ [ name ])) (List.map typeAnnotationToElmType nodes)

        TypeAnnotation.Unit ->
            Elm.Type.Tuple []

        TypeAnnotation.Tupled nodes ->
            Elm.Type.Tuple (List.map typeAnnotationToElmType nodes)

        TypeAnnotation.Record recordDefinition ->
            Elm.Type.Record
                (List.map
                    (Node.value >> (\( fieldName, fieldType ) -> ( Node.value fieldName, typeAnnotationToElmType fieldType )))
                    recordDefinition
                )
                Nothing

        TypeAnnotation.GenericRecord genericVar recordDefinition ->
            Elm.Type.Record
                (List.map
                    (Node.value >> (\( fieldName, fieldType ) -> ( Node.value fieldName, typeAnnotationToElmType fieldType )))
                    (Node.value recordDefinition)
                )
                (Just (Node.value genericVar))

        TypeAnnotation.FunctionTypeAnnotation input output ->
            Elm.Type.Lambda (typeAnnotationToElmType input) (typeAnnotationToElmType output)



-- DECLARATION LIST VISITOR


typeOfLetDeclaration : Context a -> Node Expression.LetDeclaration -> List ( String, Elm.Type.Type )
typeOfLetDeclaration context node =
    case Node.value node of
        Expression.LetFunction function ->
            typeOfFunctionDeclaration context function

        Expression.LetDestructuring _ _ ->
            []


typeOfFunctionDeclaration : Context a -> Expression.Function -> List ( String, Elm.Type.Type )
typeOfFunctionDeclaration context function =
    let
        functionName : String
        functionName =
            function.declaration
                |> Node.value
                |> .name
                |> Node.value
    in
    case function.signature of
        Just signature ->
            [ ( functionName
              , signature
                    |> Node.value
                    |> .typeAnnotation
                    |> typeAnnotationToElmType
              )
            ]

        Nothing ->
            case inferType context (function.declaration |> Node.value |> .expression) of
                Just inferredType ->
                    [ ( functionName, inferredType ) ]

                Nothing ->
                    []
