"""Public package interface for GPT Researcher.

Keep package import light-weight so submodule imports do not eagerly pull the
full agent stack (scrapers, vector stores, PDF loaders, etc.) during CLI
startup.
"""

__all__ = ["GPTResearcher"]


def __getattr__(name):
    if name == "GPTResearcher":
        from .agent import GPTResearcher
        return GPTResearcher
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
