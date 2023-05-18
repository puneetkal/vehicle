-- @parameter(infer=True)
datasetSize : Nat
datasetSize = 9129

@parameter
epsilon : Rat


type InputVector = Vector Rat 2
type OutputVector = Vector Rat 1
type NormalisedInputVector = Vector Rat 2

@network
classify : NormalisedInputVector  -> OutputVector

type Pertubation = Vector Rat 2

normClassify : InputVector -> OutputVector
normClassify x = classify x

malicious : InputVector -> Bool
malicious x = normClassify x ! 0 > 0.5

nonMalicious : InputVector -> Bool
nonMalicious x = normClassify x ! 0 < 0.5

sameClassification : InputVector -> InputVector -> Bool
sameClassification x1 x2 =
  (malicious x1 and malicious x2) or (nonMalicious x1 and nonMalicious x2)

validPertubation : Pertubation -> Bool
validPertubation p = forall i .
  if (0 : Index 2) <= i <= (1 : Index 2)
    then -epsilon <= p ! i <= epsilon
    else p ! i == 0

robustAround : InputVector -> Bool
robustAround x = forall (p : Pertubation) .
  validPertubation p => sameClassification x (x + p)

@property
robust : Bool
robust = robustAround [1000,3000]
