# Audio Intelligence provenance

- Google YAMNet MediaPipe Audio Classifier, `float32/1`.
- Official model: <https://storage.googleapis.com/mediapipe-models/audio_classifier/yamnet/float32/1/yamnet.tflite>.
- SHA-256: `4d8b4a53282dc83ef04e3e7dbc4fbc98082e34e44ed798e16c3a0cdd4c584faf`.
- Model card / Apache-2.0: <https://www.kaggle.com/models/google/yamnet>.
- Tutorial/source: <https://www.tensorflow.org/hub/tutorials/yamnet>.
- MediaPipe 0.10.21: Apache-2.0; NumPy 1.26.4: BSD-3-Clause.
- PyInstaller 6.11.1: GPL-2.0-or-later with its distribution exception.

Setup includes package metadata/notices and the model's Apache license. No training data is shipped.
YAMNet is a broad AudioSet audio-event model, not calibrated polyphonic singing detection.
Only explicit speech/singing/rap/choir/humming labels count; generic Music and Song do not.
High scores indicate risk, low scores do not prove voice absence. Windows inference is local
CPU, with 975 ms windows/480 ms hop, not 10–20 Hz SVD and not source separation.
