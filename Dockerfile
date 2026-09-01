FROM python:3.12

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends minizinc \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD ["python", "scr/run_all.py"]
