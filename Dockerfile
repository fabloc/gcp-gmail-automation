# Build stage
FROM python:3.12-alpine AS builder

# RUN apk add --no-cache ffmpeg

# Set the working directory to /app
WORKDIR /

# copy the requirements file used for dependencies
COPY /app .

RUN apk update
RUN apk add --no-cache build-base python3-dev
RUN pip install --upgrade pip setuptools

# Install any needed packages specified in requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Compile bytecode to improve startup latency
# -q: Quiet mode 
# -b: Write legacy bytecode files (.pyc) alongside source
# -f: Force rebuild even if timestamps are up-to-date
RUN python -m compileall -q -b -f .

# Run app.py when the container launches
ENTRYPOINT ["python", "-m", "flask", "run", "--host=0.0.0.0", "--port=8080"]