@parameter
epsilon : Rat

type InputVector = Vector Rat 64
type OutputVector = Vector Rat 1
type NormalisedInputVector = Vector Rat 64

type Label = Index 2

malicious = 0
nonMalicious = 1

{-
FlowIATMean =  12
FlowIATStd  =  13
FlowIATMax  =  14
FlowIATMin  =  15
FwdIATTotal =  16
FwdIATMean  =  17
FwdIATStd   =  18
FwdIATMax   =  19
FwdIATMin   =  20
BwdIATTotal =  21
BwdIATMean  =  22
BwdIATStd   =  23
BwdIATMax   =  24
BwdIATMin   =  25
-}

maxValues : InputVector
maxValues =
  [740000000,
   72000    ,
   140000   ,
   52000000 ,
   200000000,
   4400     ,
   1500     ,
   2500     ,
   1400     ,
   19000    ,
   2900     ,
   4400     ,
   4300     ,
   610000000,
   420000000,
   740000000,
   610000000,
   690000000,
   610000000,
   430000000,
   610000000,
   610000000,
   740000000,
   610000000,
   430000000,
   740000000,
   610000000,
         1  ,
         0  ,
         0  ,
         0  ,
   1400000  ,
   2800000  ,
   1400     ,
   19000    ,
   1500     ,
   2800     ,
   7700000  ,
        2   ,
       24   ,
       68   ,
   19000    ,
   210000   ,
        0   ,
        2   ,
        2   ,
       28   ,
   2700     ,
   2500     ,
   4400     ,
        0   ,
        0   ,
        0   ,
   110000000,
   77000    ,
    3000000 ,
        1   ,
   1500     ,
      0     ,
   1200     ,
   66000    ,
   66000    ,
   38000    ,
      44]

minValues : InputVector
minValues =
  [0,
  1,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
 -2,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0
  ]

validInput : InputVector -> Bool
validInput x = forall i . minValues ! i <= x ! i <= maxValues ! i

normalise : InputVector -> NormalisedInputVector
normalise x = foreach i .
  let max = maxValues ! i in
  let min = minValues ! i in
  if max == min
    then x ! i
    else (x ! i - min) / (max - min )

-------------
-- Network --
-------------

@network
classify : NormalisedInputVector -> OutputVector

normClassify : InputVector -> Label
normClassify x = if classify (normalise x) ! 0 > 0.5 then 1 else 0

----------------
-- Robustness --
----------------

type Pertubation = Vector Rat 64

validPertubation : Pertubation -> Bool
validPertubation p = forall i .
  if (11 : Index 64) <= i < (26 : Index 64)
    then -epsilon <= p ! i <= epsilon
    else p ! i == 0

robustAround : InputVector -> Label -> Bool
robustAround x l = forall (p : Pertubation) .
  validPertubation p and validInput (x + p) => normClassify (p + x) == l

-------------
-- Dataset --
-------------

-- @parameter(infer=True)
datasetSize : Nat
datasetSize = 9129

@dataset
inputDataset : Vector InputVector datasetSize

@dataset
outputDataset : Vector Label datasetSize

@property
robust : Bool
robust = robustAround (inputDataset ! 0) (outputDataset ! 0)
