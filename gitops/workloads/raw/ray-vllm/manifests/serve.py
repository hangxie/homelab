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

# vLLM only turns generated text back into structured tool_calls when a tool-call
# parser is set; with tool schemas in the prompt but no parser, the model's call
# comes back as raw JSON in `content`. The parser -- and for Llama the chat
# template that makes the output parseable -- is per model family; first
# substring match on the model id wins, unlisted models serve without tool
# parsing. Qwen3.5 writes XML <function=...> calls inside <tool_call> and
# thinks by default.
TOOL_CALL_SETTINGS = (
    ("llama-3.2", dict(
        tool_call_parser="llama3_json",
        chat_template="/home/ray/tool_chat_template_llama3.2_json.jinja",
    )),
    ("qwen3.5", dict(tool_call_parser="qwen3_coder", reasoning_parser="qwen3")),
)

def _tool_call_kwargs(model_id: str) -> dict:
    for family, kwargs in TOOL_CALL_SETTINGS:
        if family in model_id.lower():
            return dict(kwargs, enable_auto_tool_choice=True)
    return {}

# Per-model engine overrides, first substring match wins. Qwen3.5-9B pins its
# KV cache per card instead of profiling under tensor parallel 2: profiled free
# memory swung from 0.51 GiB (cold torch.compile) to 1.32 GiB (warm), and the
# warm figure hit CUDA OOM on the first prefill. 640 MiB holds one 32K sequence
# (0.56 GiB); 1.16 GiB served fine, so it leaves margin. Qwen3.5 skips the
# vision tower. Clients that omit max_tokens let thinking loop for 20K+ tokens,
# hence the default cap and thinking off unless the request opts in.
ENGINE_OVERRIDES = (
    ("qwen3.5-9b", dict(
        max_model_len=32768, language_model_only=True, kv_cache_memory_bytes=640 * 2**20,
        override_generation_config=dict(max_new_tokens=4096, temperature=0.7, top_p=0.8, top_k=20),
        default_chat_template_kwargs=dict(enable_thinking=False),
    )),
    ("qwen3.5-4b", dict(
        max_model_len=16384, language_model_only=True, gpu_memory_utilization=0.95,
        override_generation_config=dict(max_new_tokens=4096, temperature=0.7, top_p=0.8, top_k=20),
        default_chat_template_kwargs=dict(enable_thinking=False),
    )),
    # Llama 3.2 3B at 16K fits at the default utilization; the cap matches Qwen.
    ("llama-3.2-3b", dict(override_generation_config=dict(max_new_tokens=4096))),
)

def _engine_overrides(model_id: str) -> dict:
    for family, kwargs in ENGINE_OVERRIDES:
        if family in model_id.lower():
            return kwargs
    return {}

def _make_config(model_id: str) -> LLMConfig:
    engine_kwargs = dict(
        tensor_parallel_size=int(os.environ.get("TENSOR_PARALLEL_SIZE", "1")),
        gpu_memory_utilization=float(os.environ.get("GPU_MEMORY_UTILIZATION", "0.90")),
        max_num_seqs=int(os.environ.get("MAX_NUM_SEQS", "1")),
        # fp8 KV cache is emulated on these Ampere cards, and stacked on AWQ weights it
        # corrupts generation: Qwen2.5-Coder-1.5B-AWQ emitted duplicated tokens and
        # unterminated JSON until this was auto.
        kv_cache_dtype=os.environ.get("KV_CACHE_DTYPE", "auto"),
        enforce_eager=os.environ.get("ENFORCE_EAGER", "false").lower() == "true",
        enable_prefix_caching=os.environ.get("ENABLE_PREFIX_CACHING", "true").lower() == "true",
        dtype=os.environ.get("DTYPE", "auto"),
        trust_remote_code=True,
        **_tool_call_kwargs(model_id),
    )
    mml = _opt_int("MAX_MODEL_LEN")
    if mml:
        engine_kwargs["max_model_len"] = mml
    mnbt = _opt_int("MAX_NUM_BATCHED_TOKENS")
    if mnbt:
        engine_kwargs["max_num_batched_tokens"] = mnbt
    engine_kwargs.update(_engine_overrides(model_id))

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
