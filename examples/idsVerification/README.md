# IDS Verification Example

Recent work has foung that Intrusion Detection Systems (monitors used by security practitioners to detect attacks) can be fooled into incorrectly labelling malicious traffic into benign traffic. In this example we look at one such example of perturbated dataset to see if we can verify that the IDS is robust against such attacks.

This folder contains the following files:

- `dnn_3ep.onnx` - the neural network used to implement the IDS.

- `sec-prop.vcl` - the specification describing the robustness property.


## Verifying using Marabou

The controller can be verified against the specification by running the following command:

```bash
vehicle compileAndVerify \
  --specification examples/idsVerification/sec-prop.vcl \
  --network controller:examples/idsVerification/dnn_2ep.onnx \
  --verifier Marabou \
```


