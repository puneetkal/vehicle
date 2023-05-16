Property Verify IDS
‘’’

type InputVector = Vector Rat 64    -- ERM not all rat  see below
type OutputVector = Vector Rat 1

@network
classify : InputVector  -> OutputVector


 -- Made names parasble but do we even need the =1, =2 etc?

-- TotalFwdPacket                int64
-- TotalBwdpackets               int64
-- TotalLengthofFwdPacket      int64
-- TotalLengthofBwdPacket      int64
-- FwdPacketLengthMax         float64
-- FwdPacketLengthMin         float64
-- FwdPacketLengthMean        float64
-- FwdPacketLengthStd         float64
-- BwdPacketLengthMax         float64
-- BwdPacketLengthMin         float64
-- BwdPacketLengthMean        float64
-- BwdPacketLengthStd         float64
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
-- FwdPSHFlags                   int64
-- BwdPSHFlags                   int64
-- FwdURGFlags                   int64
-- BwdURGFlags                   int64
-- FwdHeaderLength               int64
-- BwdHeaderLength               int64
-- PacketLengthMin             float64
-- PacketLengthMax             float64
-- PacketLengthMean            float64
-- PacketLengthStd             float64
-- PacketLengthVariance        float64
-- FINFlagCount                  int64
-- SYNFlagCount                  int64
-- RSTFlagCount                  int64
-- PSHFlagCount                  int64
-- ACKFlagCount                  int64
-- URGFlagCount                  int64
-- CWRFlagCount                  int64
-- ECEFlagCount                  int64
-- DownUpRatio                 float64
-- AveragePacketSize           float64
-- FwdSegmentSizeAvg          float64
-- BwdSegmentSizeAvg          float64
-- FwdBytesBulkAvg              int64
-- FwdPacketBulkAvg             int64
-- FwdBulkRateAvg               int64
-- BwdBytesBulkAvg              int64
-- BwdPacketBulkAvg             int64
-- BwdBulkRateAvg               int64
-- SubflowFwdPackets             int64
-- SubflowFwdBytes               int64
-- SubflowBwdPackets             int64
-- SubflowBwdBytes               int64
-- FwdInitWinBytes              int64
-- BwdInitWinBytes              int64
-- FwdActDataPkts               int64
-- FwdSegSizeMin                int64







malicious : InputVector -> Bool
malicious x = classify x ! 0 > 0.5

nonMalicious : InputVector -> Bool
nonMalicious x = classify x ! 0 < 0.5

sameClassification : InputVector -> InputVector -> Bool
sameClassification x1 x2 =
  (malicious x1 and malicious x2) or (nonMalicious x1 and nonMalicious x2)

type Pertubation = Vector Rat 64 -- 64

@parameter
epsilon : Rat        -- if perturbed by epsilon in problem space, what does perturbation look like in input space
                     -- epsilon over min and max of that feature  (is that what pickle object is doing?)

validPertubation : Pertubation -> Bool
validPertubation p = forall i .
  if 11 <= i < 26
    then -epsilon <= p ! i <= epsilon
    else p ! i == 0

robustAround : InputVector -> Bool
robustAround x = forall (p : Pertubation) .
  validPertubation p => sameClassification x (x + p)

@parameter(infer=True)
datasetSize : Nat

@dataset
dataset : Vector InputVector datasetSize

@property
robust : Vector Bool datasetSize
robust = foreach i . robustAround (dataset ! i)

‘’’
