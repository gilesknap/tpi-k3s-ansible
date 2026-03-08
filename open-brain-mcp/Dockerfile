FROM python:3.12-slim

WORKDIR /app

# Install dependencies first (layer cache optimisation).
COPY pyproject.toml ./
RUN pip install --no-cache-dir $(python -c "
import tomllib, pathlib
d = tomllib.loads(pathlib.Path('pyproject.toml').read_text())
print(' '.join(d['project']['dependencies']))
")

COPY *.py ./

EXPOSE 8000

CMD ["uvicorn", "server:create_app", "--host", "0.0.0.0", "--port", "8000", "--factory"]
