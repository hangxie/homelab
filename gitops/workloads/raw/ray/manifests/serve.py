"""Ray Serve LLM app: builds one LLMConfig per model_id listed in the
MODELS env var (comma-separated) and exposes them under a single
OpenAI-compatible /v1 router via build_openai_app."""
import os
from ray.serve.llm import LLMConfig, LLMServingArgs, build_openai_app

MODELS = [m.strip() for m in os.environ.get("MODELS", "").split(",") if m.strip()]
if not MODELS:
    raise RuntimeError("MODELS env var must list at least one model")

def _opt_int(name):
    v = os.environ.get(name, "").strip()
    return int(v) if v and v.lower() != "auto" else None

def _make_config(model_id: str) -> LLMConfig:
    engine_kwargs = dict(
        tensor_parallel_size=1,
        gpu_memory_utilization=float(os.environ.get("GPU_MEMORY_UTILIZATION", "0.90")),
        max_num_seqs=int(os.environ.get("MAX_NUM_SEQS", "1")),
        kv_cache_dtype=os.environ.get("KV_CACHE_DTYPE", "fp8"),
        enforce_eager=os.environ.get("ENFORCE_EAGER", "false").lower() == "true",
        enable_prefix_caching=os.environ.get("ENABLE_PREFIX_CACHING", "true").lower() == "true",
        dtype=os.environ.get("DTYPE", "auto"),
        trust_remote_code=True,
        enable_auto_tool_choice=True,
    )
    mml = _opt_int("MAX_MODEL_LEN")
    if mml:
        engine_kwargs["max_model_len"] = mml
    mnbt = _opt_int("MAX_NUM_BATCHED_TOKENS")
    if mnbt:
        engine_kwargs["max_num_batched_tokens"] = mnbt

    return LLMConfig(
        model_loading_config=dict(
            model_id=model_id,
            model_source=f"/mnt/models/{model_id}",
        ),
        deployment_config=dict(
            autoscaling_config=dict(min_replicas=1, max_replicas=1),
            max_ongoing_requests=32,
        ),
        engine_kwargs=engine_kwargs,
    )

llm_configs = [_make_config(m) for m in MODELS]
app = build_openai_app(LLMServingArgs(llm_configs=llm_configs))
