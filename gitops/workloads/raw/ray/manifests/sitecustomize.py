# Runs automatically in every Python process (PYTHONPATH=/home/ray).
# Patches Ray LLM's _infer_supports_vision / _set_model_architecture so
# that transformers 5.8.x incompatibilities (missing max_position_embeddings
# on Llama-3.2, missing vision_config on some configs) don't crash the
# LLMServer actor at startup.
#
# Guard: only run in Serve replica processes (identified by _RAY_LLM_PATCH=1
# in runtime_env). Dashboard subprocesses (MetricsHead etc.) do NOT have this
# var, so they skip the 300 MB transformers import entirely — preventing the
# 9-subprocess × 300 MB = 2.7 GB overhead that starves MetricsHead at startup.
import os as _os
if _os.environ.get('_RAY_LLM_PATCH') == '1':
    import json as _json
    import transformers as _transformers
    from ray.llm._internal.serve.core.configs.llm_config import LLMConfig as _LLMConfig

    def _safe_infer_supports_vision(self, model_id_or_path):
        try:
            hf_config = _transformers.PretrainedConfig.from_pretrained(model_id_or_path)
            self._supports_vision = hasattr(hf_config, "vision_config")
        except Exception:
            try:
                with open(_os.path.join(model_id_or_path, "config.json")) as _f:
                    self._supports_vision = "vision_config" in _json.load(_f)
            except Exception:
                self._supports_vision = False

    def _safe_set_model_architecture(self, model_id_or_path=None, model_architecture=None):
        if model_id_or_path:
            try:
                hf_config = _transformers.PretrainedConfig.from_pretrained(model_id_or_path)
                if hf_config and getattr(hf_config, "architectures", None):
                    self._model_architecture = hf_config.architectures[0]
            except Exception:
                try:
                    with open(_os.path.join(model_id_or_path, "config.json")) as _f:
                        archs = _json.load(_f).get("architectures", [])
                    if archs:
                        self._model_architecture = archs[0]
                except Exception:
                    pass
        if model_architecture:
            self._model_architecture = model_architecture

    try:
        _LLMConfig._infer_supports_vision = _safe_infer_supports_vision
        _LLMConfig._set_model_architecture = _safe_set_model_architecture
    except Exception:
        pass
