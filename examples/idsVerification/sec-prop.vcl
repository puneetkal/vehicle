Property Verify IDS
‘’’
@parameter(infer=True)
datasetSize : Nat

@parameter
epsilon : Rat


type InputVector = Vector Rat datasetSize
type OutputVector = Vector Rat 1
type NormalisedInputVector = Vector Rat datasetSize

@network
classify : NormalisedInputVector  -> OutputVector


@dataset
dataset : Vector InputVector datasetSize


type Pertubation = Vector Rat datasetSize -- 64


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


maxValues : InputVector
maxValues = foreach i .
  if i == FlowIATMean then  61000000  else
  if i == FlowIATStd  then  42000000  else
  if i == FlowIATMax  then  74000000  else
  if i == FlowIATMin  then  61000000  else
  if i == FwdIATTotal then  69000000  else
  if i == FwdIATMean  then  61000000  else
  if i == FwdIATStd   then  43000000  else
  if i == FwdIATMax   then  61000000  else
  if i == FwdIATMin   then  61000000  else
  if i == BwdIATTotal then  74000000  else
  if i == BwdIATMean  then  61000000  else
  if i == BwdIATStd   then  43000000  else
  if i == BwdIATMax   then  74000000  else
  if i == BwdIATMin   then  61000000  else 0

minValues : InputVector
minValues = foreach i .  if i == FlowIATMin then -2 else 0


normalise : InputVector -> NormalisedInputVector
normalise x = foreach i . (x ! i - minValues ! i) / (maxValues ! i - minValues ! i )


normClassify : InputVector -> OutputVector
normClassify x = classify (normalise x)


malicious : InputVector -> Bool
malicious x = normClassify x ! 0 > 0.5

nonMalicious : InputVector -> Bool
nonMalicious x = normClassify x ! 0 < 0.5

sameClassification : InputVector -> InputVector -> Bool
sameClassification x1 x2 =
  (malicious x1 and malicious x2) or (nonMalicious x1 and nonMalicious x2)



validPertubation : Pertubation -> Bool
validPertubation p = forall i .
  if 11 <= i < 26
    then -epsilon <= p ! i <= epsilon
    else p ! i == 0

robustAround : InputVector -> Bool
robustAround x = forall (p : Pertubation) .
  validPertubation p => sameClassification x (x + p)



@property
robust : Vector Bool datasetSize
robust = foreach i . robustAround (dataset ! i)

‘’’
