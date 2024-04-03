import itertools
from abc import ABCMeta, abstractmethod
from dataclasses import dataclass, field
from functools import reduce
from typing import Any, Callable, Dict, Generic, SupportsFloat, SupportsInt, Tuple, Type, Union

from typing_extensions import TypeAlias, TypeVar, override

from .. import ast as vcl
from ..typing import Optimiser
from . import _numeric
from ._collections import SupportsList, SupportsVector
from .error import VehicleBuiltinUnsupported

################################################################################
### Interpretations of Vehicle builtins in Python
################################################################################

_Bool = TypeVar("_Bool")
_Index = TypeVar("_Index")
_Nat = TypeVar("_Nat")
_Int = TypeVar("_Int")
_Rat = TypeVar("_Rat")
_BoolTensor = TypeVar("_BoolTensor")
_IndexTensor = TypeVar("_IndexTensor")
_NatTensor = TypeVar("_NatTensor")
_IntTensor = TypeVar("_IntTensor")
_RatTensor = TypeVar("_RatTensor")

Unit: TypeAlias = Tuple[()]

Value: TypeAlias = Union[
    _Bool,
    _Index,
    _Nat,
    _Int,
    _Rat,
    _BoolTensor,
    _IndexTensor,
    _NatTensor,
    _IntTensor,
    _RatTensor,
    Tuple['Value', ...]
]

@dataclass(frozen=True, init=False)
class ABCBuiltins(
    Generic[
        _Index,
        _Bool,
        _Nat,
        _Int,
        _Rat,
        _BoolTensor,
        _NatTensor,
        _IntTensor,
        _RatTensor,
    ],
    metaclass=ABCMeta,
):
    optimisers: Dict[str, Optimiser[Any, _Rat]] = field(default_factory=dict)

    @abstractmethod
    def IndexType(self) -> Type[_Index]: ...

    @abstractmethod
    def BoolTensorType(self) -> Type[_BoolTensor]: ...

    @abstractmethod
    def IndexTensorType(self) -> Type[_IndexTensor]: ...

    @abstractmethod
    def NatTensorType(self) -> Type[_NatTensor]: ...

    @abstractmethod
    def IntTensorType(self) -> Type[_IntTensor]: ...

    @abstractmethod
    def RatTensorType(self) -> Type[_RatTensor]: ...

    def ListType(self) -> Tuple[]: ...

    def Unit(self) -> Tuple[()]:
        return ()

    @abstractmethod
    def Index(self): ...

    @abstractmethod
    def BoolTensor(self): ...

    @abstractmethod
    def NatTensor(self): ...

    @abstractmethod
    def IntTensor(self): ...

    @abstractmethod
    def RatTensor(self): ...

    @abstractmethod
    def NilList(self): ...

    @abstractmethod
    def ConsList(self): ...

    @abstractmethod
    def NotTensor(self): ...

    @abstractmethod
    def AndTensor(self): ...

    @abstractmethod
    def OrTensor(self): ...

    @abstractmethod
    def NegTensor(self): ...

    @abstractmethod
    def AddTensor(self): ...

    @abstractmethod
    def SubTensor(self): ...

    @abstractmethod
    def MulTensor(self): ...

    @abstractmethod
    def DivTensor(self): ...

    @abstractmethod
    def EqTensor(self): ...

    @abstractmethod
    def NeTensor(self): ...

    @abstractmethod
    def LeTensor(self): ...

    @abstractmethod
    def LtTensor(self): ...

    @abstractmethod
    def GeTensor(self): ...

    @abstractmethod
    def GtTensor(self): ...

    @abstractmethod
    def PowRatTensor(self): ...

    @abstractmethod
    def MinRatTensor(self): ...

    @abstractmethod
    def MaxRatTensor(self): ...

    @abstractmethod
    def ReduceAndTensor(self): ...

    @abstractmethod
    def ReduceOrTensor(self): ...

    @abstractmethod
    def ReduceSumTensor(self): ...

    @abstractmethod
    def ReduceTensor(self): ...

    @abstractmethod
    def EqIndex(self): ...

    @abstractmethod
    def NeIndex(self): ...

    @abstractmethod
    def LeIndex(self): ...

    @abstractmethod
    def LtIndex(self): ...

    @abstractmethod
    def GeIndex(self): ...

    @abstractmethod
    def GtIndex(self): ...

    @abstractmethod
    def LookupTensor(self): ...

    @abstractmethod
    def StackTensor(self): ...

    @abstractmethod
    def ConstTensor(self): ...

    @abstractmethod
    def FoldList(self): ...

    @abstractmethod
    def MapList(self): ...

    @abstractmethod
    def MapTensor(self): ...

    @abstractmethod
    def ZipWithTensor(self): ...

    @abstractmethod
    def Indices(self): ...

    @abstractmethod
    def Optimise(self): ...

    @abstractmethod
    def If(self): ...

    @abstractmethod
    def Forall(self): ...

    @abstractmethod
    def Exists(self): ...


AnyBuiltins: TypeAlias = ABCBuiltins[Any, Any, Any]

################################################################################
### Translation from Vehicle AST to Python AST
################################################################################


_Program = TypeVar("_Program")
_Declaration = TypeVar("_Declaration")
_Expression = TypeVar("_Expression")


class Translation(Generic[_Program, _Declaration, _Expression], metaclass=ABCMeta):
    @abstractmethod
    def translate_program(self, program: vcl.Program) -> _Program: ...

    @abstractmethod
    def translate_declaration(self, declaration: vcl.Declaration) -> _Declaration: ...

    @abstractmethod
    def translate_expression(self, expression: vcl.Expression) -> _Expression: ...


class ABCTranslation(Translation[_Program, _Declaration, _Expression]):
    @override
    def translate_program(self, program: vcl.Program) -> _Program:
        if isinstance(program, vcl.Main):
            return self.translate_Main(program)
        raise NotImplementedError(type(program).__name__)

    @abstractmethod
    def translate_Main(self, program: vcl.Main) -> _Program: ...

    @override
    def translate_declaration(self, declaration: vcl.Declaration) -> _Declaration:
        if isinstance(declaration, vcl.DefFunction):
            return self.translate_DefFunction(declaration)
        if isinstance(declaration, vcl.DefPostulate):
            return self.translate_DefPostulate(declaration)
        raise NotImplementedError(type(declaration).__name__)

    @abstractmethod
    def translate_DefFunction(self, declaration: vcl.DefFunction) -> _Declaration: ...

    @abstractmethod
    def translate_DefPostulate(self, declaration: vcl.DefPostulate) -> _Declaration: ...

    @override
    def translate_expression(self, expression: vcl.Expression) -> _Expression:
        if isinstance(expression, vcl.App):
            return self.translate_App(expression)
        if isinstance(expression, vcl.BoundVar):
            return self.translate_BoundVar(expression)
        if isinstance(expression, vcl.Builtin):
            return self.translate_Builtin(expression)
        if isinstance(expression, vcl.FreeVar):
            return self.translate_FreeVar(expression)
        if isinstance(expression, vcl.Lam):
            return self.translate_Lam(expression)
        if isinstance(expression, vcl.Let):
            return self.translate_Let(expression)
        if isinstance(expression, vcl.PartialApp):
            return self.translate_PartialApp(expression)
        if isinstance(expression, vcl.Pi):
            return self.translate_Pi(expression)
        if isinstance(expression, vcl.Universe):
            return self.translate_Universe(expression)
        raise NotImplementedError(type(expression).__name__)

    @abstractmethod
    def translate_App(self, expression: vcl.App) -> _Expression: ...

    @abstractmethod
    def translate_BoundVar(self, expression: vcl.BoundVar) -> _Expression: ...

    @abstractmethod
    def translate_Builtin(self, expression: vcl.Builtin) -> _Expression: ...

    @abstractmethod
    def translate_FreeVar(self, expression: vcl.FreeVar) -> _Expression: ...

    @abstractmethod
    def translate_Lam(self, expression: vcl.Lam) -> _Expression: ...

    def translate_Let(self, expression: vcl.Let) -> _Expression:
        return self.translate_expression(
            vcl.App(
                provenance=expression.provenance,
                function=vcl.Lam(
                    provenance=expression.provenance,
                    binders=(expression.binder,),
                    body=expression.body,
                ),
                arguments=[expression.bound],
            )
        )

    @abstractmethod
    def translate_PartialApp(self, expression: vcl.PartialApp) -> _Expression: ...

    @abstractmethod
    def translate_Pi(self, expression: vcl.Pi) -> _Expression: ...

    @abstractmethod
    def translate_Universe(self, expression: vcl.Universe) -> _Expression: ...
