"""Configuration file for the Sphinx documentation builder."""

project = "K3s Cluster Commissioning"
copyright = "2024, Giles Knap"
author = "Giles Knap"

extensions = [
    "myst_parser",
    "sphinx_copybutton",
    "sphinx_design",
    "sphinxcontrib.mermaid",
]

# MyST extensions
myst_enable_extensions = ["colon_fence"]
myst_fence_as_directive = ["mermaid"]
# Auto-generate anchors for headings up to level 3 so in-page links like
# `[ArgoCD](#argocd)` resolve without explicit `(label)=` markers.
myst_heading_anchors = 3

# Mermaid rendering
mermaid_output_format = "raw"
mermaid_init_js = """
mermaid.initialize({
    startOnLoad: true,
    securityLevel: 'loose',
    theme: 'default',
    flowchart: { useMaxWidth: true, htmlLabels: true }
});
"""

# Copy button settings
copybutton_prompt_text = r"\$ |>>> |\.\.\. "
copybutton_prompt_is_regexp = True

# General settings
master_doc = "index"
exclude_patterns = ["_build"]
pygments_style = "sphinx"

# Theme
html_theme = "pydata_sphinx_theme"

github_user = "gilesknap"
github_repo = "tpi-k3s-ansible"

html_theme_options = {
    "logo": {"image_light": "_static/logo.svg", "image_dark": "_static/logo.svg", "text": project},
    "use_edit_page_button": True,
    "github_url": f"https://github.com/{github_user}/{github_repo}",
    "navigation_with_keys": False,
}

html_context = {
    "github_user": github_user,
    "github_repo": github_repo,
    "github_version": "main",
    "doc_path": "docs",
}

html_favicon = "_static/logo.svg"
html_show_sphinx = False
html_show_copyright = False
html_static_path = ["_static"]
html_css_files = ["custom.css"]
