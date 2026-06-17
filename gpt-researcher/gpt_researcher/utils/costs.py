"""Cost estimation utilities for LLM API usage."""

from __future__ import annotations

from typing import Any

import tiktoken

# Per OpenAI Pricing Page: https://openai.com/api/pricing/
ENCODING_MODEL = "o200k_base"
INPUT_COST_PER_TOKEN = 0.000005
OUTPUT_COST_PER_TOKEN = 0.000015
IMAGE_INFERENCE_COST = 0.003825
EMBEDDING_COST = 0.02 / 1000000  # Assumes new ada-3-small


def _bedrock_rate_card_per_million(model_name: str | None) -> dict[str, float]:
    """Return a simple Bedrock rate card for supported Anthropic models.

    Rates are estimates in USD per 1M tokens and are intended for telemetry.
    """
    model = (model_name or "").lower()
    if "opus" in model:
        return {
            "input": 5.0,
            "output": 25.0,
            "cache_read": 0.5,
            "cache_write": 6.25,
        }
    if "haiku" in model:
        return {
            "input": 0.8,
            "output": 4.0,
            "cache_read": 0.08,
            "cache_write": 1.0,
        }
    # Default to Sonnet-family pricing.
    return {
        "input": 3.0,
        "output": 15.0,
        "cache_read": 0.3,
        "cache_write": 3.75,
    }


def estimate_bedrock_cost_from_usage(
    usage: dict[str, Any] | None,
    model_name: str | None,
) -> float:
    """Estimate Bedrock cost from token usage payload."""
    if not usage:
        return 0.0
    rates = _bedrock_rate_card_per_million(model_name)
    input_tokens = int(usage.get("inputTokens", usage.get("input_tokens", 0)) or 0)
    output_tokens = int(usage.get("outputTokens", usage.get("output_tokens", 0)) or 0)
    cache_read_tokens = int(
        usage.get(
            "cacheReadInputTokens",
            usage.get("cache_read_input_tokens", usage.get("input_token_details", {}).get("cache_read", 0)),
        )
        or 0
    )
    cache_write_tokens = int(
        usage.get(
            "cacheWriteInputTokens",
            usage.get("cache_write_input_tokens", usage.get("input_token_details", {}).get("cache_creation", 0)),
        )
        or 0
    )
    return (
        (input_tokens * rates["input"])
        + (output_tokens * rates["output"])
        + (cache_read_tokens * rates["cache_read"])
        + (cache_write_tokens * rates["cache_write"])
    ) / 1_000_000.0


def estimate_llm_cost(input_content: str, output_content: str) -> float:
    """Estimate the cost of an LLM API call based on input and output content.

    Cost estimation is based on OpenAI pricing and may vary for other models.

    Args:
        input_content: The input text sent to the LLM.
        output_content: The output text received from the LLM.

    Returns:
        The estimated cost in USD.
    """
    encoding = tiktoken.get_encoding(ENCODING_MODEL)
    input_tokens = encoding.encode(input_content)
    output_tokens = encoding.encode(output_content)
    input_costs = len(input_tokens) * INPUT_COST_PER_TOKEN
    output_costs = len(output_tokens) * OUTPUT_COST_PER_TOKEN
    return input_costs + output_costs


def estimate_embedding_cost(model: str, docs: list) -> float:
    """Estimate the cost of embedding documents.

    Args:
        model: The embedding model name.
        docs: List of documents to embed.

    Returns:
        The estimated embedding cost in USD.
    """
    encoding = tiktoken.encoding_for_model(model)
    total_tokens = sum(len(encoding.encode(str(doc))) for doc in docs)
    return total_tokens * EMBEDDING_COST
