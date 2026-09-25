# Wake-word models

| File | Source | Licence |
| --- | --- | --- |
| `melspectrogram.onnx` | [openWakeWord v0.5.1 release](https://github.com/dscripka/openWakeWord/releases/tag/v0.5.1) | Apache-2.0 |
| `embedding_model.onnx` | [openWakeWord v0.5.1 release](https://github.com/dscripka/openWakeWord/releases/tag/v0.5.1) (Google speech_embedding) | Apache-2.0 |
| `alfred.onnx` | [home-assistant-wakewords-collection `en/alfred`](https://github.com/fwartner/home-assistant-wakewords-collection) | MIT (collection). openWakeWord-trained models are otherwise CC BY-NC-SA 4.0: personal, non-commercial use only. |

SHA-256 at download (2026-09-25):

```
ba2b0e0f8b7b875369a2c89cb13360ff53bac436f2895cced9f479fa65eb176f  melspectrogram.onnx
70d164290c1d095d1d4ee149bc5e00543250a7316b59f31d056cff7bd3075c1f  embedding_model.onnx
6b67237ff9da3bf00cb443438503ef842655263b62323f7da48e3f7c2e81940e  alfred.onnx
```

To use a custom-trained model instead, replace `alfred.onnx` with the `.onnx` the openWakeWord training notebook produces.
