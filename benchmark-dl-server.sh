#!/bin/bash
TF_XLA_FLAGS='--tf_xla_auto_jit=2 --tf_xla_cpu_global_jit --tf_xla_enable_xla_devices' XLA_FLAGS='--xla_gpu_cuda_data_dir=/usr/local/cuda' TF_CPP_MIN_LOG_LEVEL=3 ./batch_benchmark.sh 2 2 1 10 2 ./config/config_all
