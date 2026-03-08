FROM python:3.12-slim

WORKDIR /app

# Copy all source files (pyproject.toml + *.py) then install.
# pip install . reads pyproject.toml and installs the declared dependencies.
COPY pyproject.toml *.py ./
RUN pip install --no-cache-dir .

EXPOSE 8000

CMD ["uvicorn", "server:create_app", "--host", "0.0.0.0", "--port", "8000", "--factory"]
