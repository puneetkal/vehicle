# File generated by the BNF Converter (bnfc 2.9.4.1).

import pygments.lexer
from pygments.token import *

__all__ = ["ExternalLexer"]


class ExternalLexer(pygments.lexer.RegexLexer):
    name = "External"
    aliases = ["external"]
    KEYWORDS = ["in", "type"]

    def get_tokens_unprocessed(self, text):
        for index, token, value in super(ExternalLexer, self).get_tokens_unprocessed(
            text
        ):
            if token is Name and value in self.KEYWORDS:
                yield index, Keyword, value
            else:
                yield index, token, value

    tokens = {
        "root": [
            (r"--.*\n", Comment),
            (r"\{-((.)(?<!-))*-((.)(?<![-\}])((.)(?<!-))*-|-)*\}", Comment),
            (r"True|False", Name),
            (r"(\d)+", Name),
            (r"(\d)+\.(\d)+", Name),
            (r"@network", Name),
            (r"@dataset", Name),
            (r"@parameter", Name),
            (r"@property", Name),
            (r"@postulate", Name),
            (r"@noinline", Name),
            (r"->", Name),
            (r"forallT", Name),
            (r"if", Name),
            (r"then", Name),
            (r"else", Name),
            (r"\.", Name),
            (r":", Name),
            (r"\\", Name),
            (r"let", Name),
            (r"Type", Name),
            (r"Unit", Name),
            (r"Bool", Name),
            (r"Nat", Name),
            (r"Int", Name),
            (r"Rat", Name),
            (r"Vector", Name),
            (r"List", Name),
            (r"Index", Name),
            (r"forall", Name),
            (r"exists", Name),
            (r"foreach", Name),
            (r"=>", Name),
            (r"and", Name),
            (r"or", Name),
            (r"not", Name),
            (r"==", Name),
            (r"!=", Name),
            (r"<=", Name),
            (r"<", Name),
            (r">=", Name),
            (r">", Name),
            (r"\*", Name),
            (r"/", Name),
            (r"\+", Name),
            (r"-", Name),
            (r"nil", Name),
            (r"::", Name),
            (r"\[", Name),
            (r"\]", Name),
            (r"::v", Name),
            (r"!", Name),
            (r"map", Name),
            (r"fold", Name),
            (r"dfold", Name),
            (r"indices", Name),
            (r"fromNat", Name),
            (r"fromInt", Name),
            (r"HasEq", Name),
            (r"HasNotEq", Name),
            (r"HasAdd", Name),
            (r"HasSub", Name),
            (r"HasMul", Name),
            (r"HasFold", Name),
            (r"HasMap", Name),
            (r"[a-zA-Z](_|\d|[a-zA-Z])*", Name),
            (r"\?(_|\d|[a-zA-Z])*", Name),
            (r"(\d|[a-zA-Z])+", Name),
            (r"[a-zA-Z]([a-zA-Z]|\d|_|\')*", Name),
            (r"\(|\)|\{|\}|\{\{|\}\}|=|,|\(\)|;", Operator),
            (r"(\d)+", Number.Integer),
            (r"(\d)+\.(\d)+(e(-)?(\d)+)?", Number.Float),
            (r'"((.)(?<!["\\])|\\["\\nt])*"', String.Double),
            (r"\'((.)(?<![\'\\])|\\[\'\\nt])\'", String.Char),
            (r"\s+", Token.Space),
        ]
    }
