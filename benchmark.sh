#!/bin/bash -e

GPU_INDEX=${1:-0}
IFS=', ' read -r -a gpus <<< "$GPU_INDEX"

ITERATIONS=${2:-100}
NUM_BATCHES=${3:-100}
THERMAL_INTERVAL=${4:-1}

MIN_NUM_GPU=${#gpus[@]}
MAX_NUM_GPU=$MIN_NUM_GPU
export CUDA_VISIBLE_DEVICES=$GPU_INDEX

SCRIPT_DIR="$(pwd)/benchmarks/scripts/tf_cnn_benchmarks"

CPU_NAME="$(lscpu | awk '/Model\ name:/ {
  # CPU can show up at different locations
  if($5 ~ "CPU") print $4;
  else print $5;
  exit
}')"

GPU_NAME="$([ which nvidia-smi &>/dev/null ] && nvidia-smi -i 0 --query-gpu=gpu_name --format=csv,noheader || echo PLACEHOLDER )"
GPU_NAME="${GPU_NAME// /_}"

CONFIG_NAME="${CPU_NAME}-${GPU_NAME}"
echo $CONFIG_NAME


DATA_DIR="/home/${USER}/nfs/imagenet_mini"
LOG_DIR="$(pwd)/${CONFIG_NAME}.logs"


MODELS=(
  resnet50
  resnet152
  inception3
  inception4
  vgg16
  alexnet
  ssd300
)

VARIABLE_UPDATE=(
  replicated
#  parameter_server
)

DATA_MODE=(
  syn
#  real
)

PRECISION=(
  fp32
  fp16
)

RUN_MODE=(
  train
  inference
)

# # For GPUs with ~6 GB memory
# declare -A BATCH_SIZES=(
#  [resnet50]=32
#  [resnet152]=16
#  [inception3]=32
#  [inception4]=8
#  [vgg16]=32
#  [alexnet]=256
#  [ssd300]=16
# )


# # For GPUs with ~8 GB memory
# declare -A BATCH_SIZES=(
#  [resnet50]=48
#  [resnet152]=32
#  [inception3]=48
#  [inception4]=12
#  [vgg16]=48
#  [alexnet]=384
#  [ssd300]=32
# )


## For GPUs with ~12 GB memory
#declare -A BATCH_SIZES=(
# [resnet50]=64
# [resnet152]=32
# [inception3]=64
# [inception4]=16
# [vgg16]=64
# [alexnet]=512
# [ssd300]=32
#)

# For GPUs with ~24 GB memory
# declare -A BATCH_SIZES=(
#   [resnet50]=128
#   [resnet152]=64
#   [inception3]=128
#   [inception4]=32
#   [vgg16]=128
#   [alexnet]=1024
#   [ssd300]=64
# )

# For GPUs with ~32 GB memory
declare -A BATCH_SIZES=(
  [resnet50]=192
  [resnet152]=96
  [inception3]=192
  [inception4]=48
  [vgg16]=192
  [alexnet]=1536
  [ssd300]=96
)

## For GPUs with ~48 GB memory
#declare -A BATCH_SIZES=(
#  [resnet50]=256
#  [resnet152]=128
#  [inception3]=256
#  [inception4]=64
#  [vgg16]=256
#  [alexnet]=2048
#  [ssd300]=128
#)

declare -A DATASET_NAMES=(
  [resnet50]=imagenet
  [resnet101]=imagenet
  [resnet152]=imagenet
  [inception3]=imagenet
  [inception4]=imagenet
  [vgg16]=imagenet
  [alexnet]=imagenet
  [ssd300]=coco  
)


run_benchmark() {

  local model="$1"
  local batch_size=$2
  local config_name=$3
  local num_gpus=$4
  local iter=$5
  local data_mode=$6
  local update_mode=$7
  local distortions=$8
  local dataset_name=$9
  local precision="${10}"
  local run_mode="${11}"

  pushd "$SCRIPT_DIR" &> /dev/null
  local args=()

  # Example: syn-replicated-fp32-1gpus
  local outer_dir="${data_mode}-${variable_update}-${precision}-${num_gpus}gpus"

  args+=("--optimizer=sgd")
  args+=("--model=$model")
  args+=("--num_gpus=$num_gpus")
  args+=("--batch_size=$batch_size")
  args+=("--variable_update=$variable_update")
  args+=("--distortions=$distortions")
  args+=("--num_batches=$NUM_BATCHES")
  args+=("--data_name=$dataset_name")
  args+=("--all_reduce_spec=nccl")

  if [ $data_mode = real ]; then
    args+=("--data_dir=$DATA_DIR")
  fi
  if $distortions; then
    outer_dir+="-distortions"
  fi
  if [ $precision = fp16 ]; then
    args+=("--use_fp16=True")
  fi
  if [ $run_mode == inference ]; then
    args+=("--forward_only=True")
    outer_dir+="-inference"
  fi

  inner_dir="${model}-${batch_size}"
  local         output="${LOG_DIR}/${outer_dir}/${inner_dir}/${iter}"
  local output_thermal="${LOG_DIR}/${outer_dir}/${inner_dir}/thermal/${iter}"
  
  rm -f $output
  rm -f $output_thermal
  mkdir -p "$(dirname $output)" || true
  mkdir -p "$(dirname $output_thermal)" || true
  
  # echo $output
  echo ${args[@]}

  run_thermal >> $output_thermal &
  thermal_loop="$!" # process ID of while loop

  stdbuf -oL  python3 tf_cnn_benchmarks.py "${args[@]}" |& tee "$output"

  kill "$thermal_loop"
  popd &> /dev/null
}

run_thermal() {
  local num_sec=0
  while :; do
	  local info="$(nvidia-smi \
		  --query-gpu=temperature.gpu,utilization.gpu,utilization.memory\
		  --format=csv,noheader,nounits)"
	  printf "${num_sec}\n${info}\n\n"
	  num_sec=$((num_sec + THERMAL_INTERVAL))
	  sleep $THERMAL_INTERVAL
  done
}

run_benchmark_all() {
  for model in "${MODELS[@]}"; do
    local batch_size=${BATCH_SIZES[$model]}
    local dataset_name=${DATASET_NAMES[$model]}
    for num_gpu in `seq ${MAX_NUM_GPU} -1 ${MIN_NUM_GPU}`; do 
      for iter in $(seq 1 $ITERATIONS); do
        run_benchmark "$model" $batch_size $CONFIG_NAME $num_gpu $iter $data_mode $variable_update $distortions $dataset_name $precision $run_mode
      done
    done
  done  
}



main() {
  for run_mode in "${RUN_MODE[@]}"; do
    for precision in "${PRECISION[@]}"; do
      for data_mode in "${DATA_MODE[@]}"; do
        for variable_update in "${VARIABLE_UPDATE[@]}"; do
          for distortions in true false; do
            if [ $data_mode = syn ] && $distortions ; then
              # skip distortion for synthetic data
              :
            else
              run_benchmark_all
            fi
          done
        done
      done
    done
  done


}

main "$@"
