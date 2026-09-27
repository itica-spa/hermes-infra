FROM ubuntu:24.04

RUN apt update && apt install -y curl git ca-certificates libatomic1 libstdc++6 && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash

ENV PATH="/root/.hermes/bin:${PATH}"

WORKDIR /root
CMD ["bash"]
