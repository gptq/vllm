# The vLLM Dockerfile is used to construct vLLM image that can be directly used
# to run the OpenAI compatible server.

#################### BASE BUILD IMAGE ####################
# prepare basic build environment
#FROM nvidia/cuda:12.1.0-devel-ubuntu22.04 AS dev
#ARG PYPI_MIRROR=https://pypi.mirrors.ustc.edu.cn/simple/
FROM nvidia/cuda:12.1.0-cudnn8-devel-ubuntu22.04 AS dev
ARG PYPI_MIRROR
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY

# 替换为科大源
RUN sed -i 's/http:\/\/archive.ubuntu.com\/ubuntu\//http:\/\/mirrors.ustc.edu.cn\/ubuntu\//g' /etc/apt/sources.list && \
    apt-get update -y && \
    apt-get install -y python3-pip git
    


# Workaround for https://github.com/openai/triton/issues/2507 and
# https://github.com/pytorch/pytorch/issues/107960 -- hopefully
# this won't be needed for future versions of this docker image
# or future versions of triton.
# 使用代理进行操作，如安装包等
RUN export http_proxy=$HTTP_PROXY && \
    export https_proxy=$HTTPS_PROXY && \
    export no_proxy=$NO_PROXY && \
    ldconfig /usr/local/cuda-12.1/compat/

WORKDIR /workspace

# install build and runtime dependencies
COPY requirements-common.txt requirements-common.txt
COPY requirements-cuda.txt requirements-cuda.txt
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --index-url ${PYPI_MIRROR}  -r requirements-cuda.txt

# install development dependencies
COPY requirements-dev.txt requirements-dev.txt
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --index-url ${PYPI_MIRROR}  -r requirements-dev.txt

# cuda arch list used by torch
# can be useful for both `dev` and `test`
# explicitly set the list to avoid issues with torch 2.2
# see https://github.com/pytorch/pytorch/pull/123243
ARG torch_cuda_arch_list='7.0 7.5 8.0 8.6 8.9 9.0+PTX'
ENV TORCH_CUDA_ARCH_LIST=${torch_cuda_arch_list}
#################### BASE BUILD IMAGE ####################


#################### WHEEL BUILD IMAGE ####################
FROM dev AS build
ARG PYPI_MIRROR
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY


# install build dependencies
COPY requirements-build.txt requirements-build.txt
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --index-url ${PYPI_MIRROR}  -r requirements-build.txt

# install compiler cache to speed up compilation leveraging local or remote caching
# 替换为科大源
RUN sed -i 's/http:\/\/archive.ubuntu.com\/ubuntu\//http:\/\/mirrors.ustc.edu.cn\/ubuntu\//g' /etc/apt/sources.list && \
    apt-get update -y && \
    apt-get install -y ccache

# files and directories related to build wheels
COPY csrc csrc
COPY setup.py setup.py
COPY cmake cmake
COPY CMakeLists.txt CMakeLists.txt
COPY requirements-common.txt requirements-common.txt
COPY requirements-cuda.txt requirements-cuda.txt
COPY pyproject.toml pyproject.toml
COPY vllm vllm

# max jobs used by Ninja to build extensions
ARG max_jobs=2
ENV MAX_JOBS=${max_jobs}
# number of threads used by nvcc
ARG nvcc_threads=8
ENV NVCC_THREADS=$nvcc_threads
# make sure punica kernels are built (for LoRA)
ENV VLLM_INSTALL_PUNICA_KERNELS=1

ENV CCACHE_DIR=/root/.cache/ccache
# 使用代理进行操作，如安装包等
RUN export http_proxy=$HTTP_PROXY && \
    export https_proxy=$HTTPS_PROXY && \
    export no_proxy=$NO_PROXY && \
    --mount=type=cache,target=/root/.cache/ccache \
    --mount=type=cache,target=/root/.cache/pip \
    python3 setup.py bdist_wheel --dist-dir=dist

# the `vllm_nccl` package must be installed from source distribution
# pip is too smart to store a wheel in the cache, and other CI jobs
# will directly use the wheel from the cache, which is not what we want.
# we need to remove it manually
# 使用代理进行操作，如安装包等
RUN export http_proxy=$HTTP_PROXY && \
    export https_proxy=$HTTPS_PROXY && \
    export no_proxy=$NO_PROXY && \
    --mount=type=cache,target=/root/.cache/pip \
    pip cache remove vllm_nccl*
#################### EXTENSION Build IMAGE ####################

#################### FLASH_ATTENTION Build IMAGE ####################
FROM dev as flash-attn-builder
ARG PYPI_MIRROR
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY


# max jobs used for build
ARG max_jobs=2
ENV MAX_JOBS=${max_jobs}
# flash attention version
ARG flash_attn_version=v2.5.6
ENV FLASH_ATTN_VERSION=${flash_attn_version}

WORKDIR /usr/src/flash-attention-v2

# Download the wheel or build it if a pre-compiled release doesn't exist
# 使用代理进行操作，如安装包等
RUN export http_proxy=$HTTP_PROXY && \
    export https_proxy=$HTTPS_PROXY && \
    export no_proxy=$NO_PROXY && \
    pip --verbose wheel flash-attn==${FLASH_ATTN_VERSION} \
    --no-build-isolation --no-deps --no-cache-dir

#################### FLASH_ATTENTION Build IMAGE ####################

#################### vLLM installation IMAGE ####################
# image with vLLM installed
FROM nvidia/cuda:12.1.0-base-ubuntu22.04 AS vllm-base
ARG PYPI_MIRROR
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY

WORKDIR /vllm-workspace

# 替换为科大源
RUN sed -i 's/http:\/\/archive.ubuntu.com\/ubuntu\//http:\/\/mirrors.ustc.edu.cn\/ubuntu\//g' /etc/apt/sources.list && \
    apt-get update -y && \
    apt-get install -y python3-pip git vim
    


# Workaround for https://github.com/openai/triton/issues/2507 and
# https://github.com/pytorch/pytorch/issues/107960 -- hopefully
# this won't be needed for future versions of this docker image
# or future versions of triton.
## 使用代理进行操作，如安装包等
RUN ldconfig /usr/local/cuda-12.1/compat/

# install vllm wheel first, so that torch etc will be installed
# 使用代理进行操作，如安装包等
RUN --mount=type=bind,from=build,src=/workspace/dist,target=/vllm-workspace/dist \
    --mount=type=cache,target=/root/.cache/pip \
    pip install --index-url ${PYPI_MIRROR}  dist/*.whl --verbose

# 使用代理进行操作，如安装包等
RUN export http_proxy=$HTTP_PROXY && \
    export https_proxy=$HTTPS_PROXY && \
    export no_proxy=$NO_PROXY && \
    --mount=type=bind,from=flash-attn-builder,src=/usr/src/flash-attention-v2,target=/usr/src/flash-attention-v2 \
    --mount=type=cache,target=/root/.cache/pip \
    pip install --index-url ${PYPI_MIRROR}  /usr/src/flash-attention-v2/*.whl --no-cache-dir
#################### vLLM installation IMAGE ####################


#################### TEST IMAGE ####################
# image to run unit testing suite
# note that this uses vllm installed by `pip`
FROM vllm-base AS test
ARG PYPI_MIRROR
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY


ADD . /vllm-workspace/

# install development dependencies (for testing)
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --index-url ${PYPI_MIRROR}  -r requirements-dev.txt

# doc requires source code
# we hide them inside `test_docs/` , so that this source code
# will not be imported by other tests
RUN mkdir test_docs
RUN mv docs test_docs/
RUN mv vllm test_docs/

#################### TEST IMAGE ####################

#################### OPENAI API SERVER ####################
# openai api server alternative
FROM vllm-base AS vllm-openai
ARG PYPI_MIRROR
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY


# install additional dependencies for openai api server
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --index-url ${PYPI_MIRROR}  accelerate hf_transfer modelscope  auto-gptq deepspeed datasets jsonlines peft safetensors torch transformers fastapi uvicorn streamlit

ENV VLLM_USAGE_SOURCE production-docker-image

#ENTRYPOINT ["python3", "-m", "vllm.entrypoints.openai.api_server"]
#################### OPENAI API SERVER ####################
