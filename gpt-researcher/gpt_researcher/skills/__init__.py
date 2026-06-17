"""Lazy exports for skill classes.

Avoid importing the whole skills tree at package import time. The CLI only needs
specific classes, and eager imports can trigger a large dependency cascade
before research even starts.
"""

__all__ = [
    "ResearchConductor",
    "ReportGenerator",
    "ContextManager",
    "BrowserManager",
    "SourceCurator",
    "ImageGenerator",
]


def __getattr__(name):
    if name == "ContextManager":
        from .context_manager import ContextManager
        return ContextManager
    if name == "ResearchConductor":
        from .researcher import ResearchConductor
        return ResearchConductor
    if name == "ReportGenerator":
        from .writer import ReportGenerator
        return ReportGenerator
    if name == "BrowserManager":
        from .browser import BrowserManager
        return BrowserManager
    if name == "SourceCurator":
        from .curator import SourceCurator
        return SourceCurator
    if name == "ImageGenerator":
        from .image_generator import ImageGenerator
        return ImageGenerator
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
