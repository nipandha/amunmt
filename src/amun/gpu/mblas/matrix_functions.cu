#include "gpu/mblas/matrix_functions.h"

#include "gpu/mblas/handles.h"

namespace amunmt {
namespace GPU {
namespace mblas {

thread_local cublasHandle_t* CublasHandler::handle_ = nullptr;
thread_local CudaStreamHandler* CudaStreamHandler::instance_ = nullptr;;

Matrix& Swap(Matrix& Out, Matrix& In) {
  Out.swap(In);
  return Out;
}

__global__ void gMean(float* d_out, const float* d_in, const int* mapping,
                      int batchNum, int senLen, int stateLength) {
  int id = threadIdx.x + blockIdx.x * blockDim.x;
  if (id < stateLength) {
    float sum = 0.0f;
    int counter = 0;

    for (int i = 0; i < batchNum * senLen; ++i) {
      sum += mapping[i] * d_in[i * stateLength + id];
      counter += mapping[i];

      if ((i + 1) % senLen == 0) {
        sum /= counter;
        d_out[(i / senLen) * stateLength + id] = sum;
        sum = 0.0f;
        counter = 0;
      }
    }
  }
}

void Mean(Matrix& Out, const Matrix& In, const DeviceVector<int>& mapping) {
  int batchNum = Out.dim(0) * Out.dim(2) * Out.dim(3);
  int stateLength = Out.dim(1);
  int sentenceLength = (In.dim(0) * In.dim(2) * In.dim(3)) / batchNum;

  int nThreads = 512;
  int nBlocks =  (stateLength / 512) + ((stateLength % 512 == 0) ?  0 : 1);

  gMean<<<nBlocks, nThreads, 0, CudaStreamHandler::GetStream()>>>
    (Out.data(), In.data(), thrust::raw_pointer_cast(mapping.data()),
     batchNum, sentenceLength, stateLength);
}

__global__ void gWeightedMean(float* d_out, const float* weights, const float* d_in, const int* mapping,
                              int numRows, int numCols, int srcLen) {
  int id = threadIdx.x + blockIdx.x * blockDim.x;
  if (id < numRows * numCols) {
    int rowNo = id / numCols;
    int batchNo = mapping[rowNo];
    int statePos = id % numCols;

    float sum = 0.0f;
    for (int i = 0; i < srcLen; ++i) {
      sum += weights[rowNo * srcLen + i] * d_in[batchNo * srcLen * numCols + (i * numCols) + statePos];
    }

    d_out[id] = sum;
  }
}

void WeightedMean(Matrix& Out,const Matrix& Weights, const Matrix& In, const DeviceVector<int>& mapping) {
  int numRows = Weights.dim(0);
  int numCols = In.dim(1);

  Out.Resize(numRows, numCols);

  int nThreads = 512;
  int nBlocks =  (Out.size() / 512) + ((Out.size() % 512 == 0) ?  0 : 1);

  gWeightedMean<<<nBlocks, nThreads, 0, CudaStreamHandler::GetStream()>>>
    (Out.data(), Weights.data(), In.data(), thrust::raw_pointer_cast(mapping.data()),
     numRows, numCols, Weights.dim(1));
}

Matrix& Transpose(Matrix& Out, const Matrix& In) {
  size_t m = In.dim(0);
  size_t n = In.dim(1);

  Out.Resize(n, m);

  float alpha = 1.0;
  float beta  = 0.0;

  cublasSgeam(CublasHandler::GetHandle(), CUBLAS_OP_T, CUBLAS_OP_T, m, n, &alpha, In.data(), n,
              &beta, In.data(), n, Out.data(), m);

  return Out;
}

Matrix& Transpose(Matrix& Out) {
  Matrix Temp;
  Transpose(Temp, Out);
  Swap(Out, Temp);
  return Out;
}

Matrix& Concat(Matrix& Out, const Matrix& In) {
  size_t oldSize = Out.size();
  Out.Resize(Out.dim(0) + In.dim(0), Out.dim(1));

  mblas::copy(In.data(), In.size(), Out.data() + oldSize, cudaMemcpyDeviceToDevice);

  return Out;
}

Matrix& Copy(Matrix& Out, const Matrix& In) {
  Out.Resize(In.dim(0), In.dim(1), In.dim(2), In.dim(3));

  mblas::copy(In.data(), In.size(), Out.data(), cudaMemcpyDeviceToDevice);

  return Out;
}

__global__ void gPasteRows(float* d_out, int outRows, int outCols, const float* d_in, int inRows, int inCols, int colNo, int sparse) {
  int id = threadIdx.x + blockIdx.x * blockDim.x;
  if (id < inRows * inCols) {
    int inRow = id / inCols;
    int inCol = id % inCols;
    int outID = (outRows + sparse * inRow) * outCols + inCol + colNo;
    d_out[outID] = d_in[id];
  }
}
void PasteRows(Matrix& Out, const Matrix& In, const size_t rowNo, size_t colNo, size_t sparse) {
  int nColumns = In.dim(1);
  int nRows = In.dim(0);
  int nThreads = 512;
  int nBlocks =  (In.size() / 512) + ((In.size() % 512 == 0) ?  0 : 1);


  gPasteRows<<<nBlocks, nThreads, 0, CudaStreamHandler::GetStream()>>>
    (Out.data(), rowNo, Out.dim(1), In.data(), In.dim(0), In.dim(1), colNo, sparse);
}

Matrix& PasteRow(Matrix& Out,
                 const Matrix& In,
                 const size_t r, const size_t c) {
  size_t start = r * Out.dim(1) + c;

  mblas::copy(In.data(), In.size(), Out.data() + start, cudaMemcpyDeviceToDevice);

  return Out;
}

Matrix& CopyRow(Matrix& Out,
                const Matrix& In,
                const size_t r, const size_t c) {
  size_t length = In.dim(1) - c;
  Out.Resize(1, length);
  size_t start = r * In.dim(1) + c;
  //size_t end   = start + length;

  //mblas::copy(In.begin() + start, In.begin() + end, Out.begin());
  mblas::copy(In.data() + start, length , Out.data(), cudaMemcpyDeviceToDevice);

  return Out;
}

__global__ void gCopyRows(float* out, const float* in, size_t cols,
                          const size_t* targetRowIdx, size_t numPairs) {
  for (int bid = 0; bid < numPairs; bid += gridDim.x) {
    int j = bid + blockIdx.x;
    if (j < numPairs) {
      size_t dstId = j;
      size_t srcId = targetRowIdx[j];

      float* rowOut = out + dstId * cols;
      const float* rowIn = in + srcId * cols;

      for(int tid = 0; tid < cols; tid += blockDim.x) {
        int i = tid + threadIdx.x;
        if(i < cols)
          rowOut[i] = rowIn[i];
      }
    }
  }
}

Matrix& CopyRows(Matrix& Out,
                 const Matrix& In,
                 const size_t* dev,
                 size_t numPairs) {
  float* d_out = Out.data();
  const float* d_in = In.data();

  int threads = std::min(MAX_THREADS, (int)In.dim(1));
  int blocks = std::min(MAX_BLOCKS, (int)numPairs);

  gCopyRows<<<blocks, threads, 0, CudaStreamHandler::GetStream()>>>
    (d_out, d_in, In.dim(1), dev, numPairs);

  return Out;
}


Matrix& Assemble(Matrix& Out,
                 const Matrix& In,
                 const DeviceVector<size_t>& indeces) {
  Out.Resize(indeces.size(), In.dim(1));
  CopyRows(Out, In, thrust::raw_pointer_cast(indeces.data()), indeces.size());
  return Out;
}

__global__ void gSlice(float* out, const float* in,
                       size_t n, size_t dim,
                       size_t rows, size_t cols) {
  for(int bid = 0; bid < rows; bid += gridDim.x) {
    int j = bid + blockIdx.x;
    if(j < rows) {
      float* rowOut = out + j * dim;
      const float* rowIn = in + j * cols + n * dim;

      for(int tid = 0; tid < dim; tid += blockDim.x) {
        int i = tid + threadIdx.x;
        if(i < dim)
          rowOut[i] = rowIn[i];
      }
    }
  }
}

Matrix& Slice(Matrix& Out,
              const Matrix& In,
              size_t n, size_t dim) {

  Out.Resize(In.dim(0), dim);

  float* d_out = Out.data();
  const float* d_in = In.data();

  int threads = std::min(MAX_THREADS, (int)dim);
  int blocks = std::min(MAX_BLOCKS, (int)In.dim(0));

  gSlice<<<blocks, threads, 0, CudaStreamHandler::GetStream()>>>
    (d_out, d_in, n, dim, In.dim(0), In.dim(1));
  return Out;
}

Matrix& Prod(cublasHandle_t handle, Matrix& C, const Matrix& A, const Matrix& B,
             bool transA, bool transB) {
  Matrix::value_type alpha = 1.0;
  Matrix::value_type beta = 0.0;

  size_t m = A.dim(0);
  size_t k = A.dim(1);
  if(transA)
    std::swap(m, k);

  size_t l = B.dim(0);
  size_t n = B.dim(1);
  if(transB)
    std::swap(l, n);

  size_t lda = A.dim(1);
  size_t ldb = B.dim(1);
  size_t ldc = B.dim(1);

  if(transB)
    ldc = B.dim(0);

  C.Resize(m, n, A.dim(2), A.dim(3));

  cublasOperation_t opA = transA ? CUBLAS_OP_T : CUBLAS_OP_N;
  cublasOperation_t opB = transB ? CUBLAS_OP_T : CUBLAS_OP_N;

  size_t m2 = A.dim(0) * A.dim(2) * A.dim(3);

  cublasSgemm(handle, opB, opA,
              n, m2, k, &alpha, B.data(), ldb, A.data(), lda, &beta, C.data(), ldc);
  return C;
}

Matrix& Prod(Matrix& C, const Matrix& A, const Matrix& B,
             bool transA, bool transB) {

  //std::cerr << "1C=" << C.Debug() << std::endl;
  //std::cerr << "1A=" << A.Debug() << std::endl;
  //std::cerr << "1B=" << B.Debug() << std::endl;

  Matrix &ret = Prod(CublasHandler::GetHandle(), C, A, B, transA, transB);

  //std::cerr << "2C=" << C.Debug() << std::endl;
  return ret;
}

__global__ void gSoftMax(float* softMaxP, size_t rows, size_t cols,
                         const int* batchID,
                         int batchNum,
                         const int* srcMapping,
                         int srcNum) {
  extern __shared__ float _share[];

  int rowIdx =  blockIdx.x;

  while (rowIdx < rows) {
    float* row = softMaxP + rowIdx * cols;

    float* _max = _share;
    _max[threadIdx.x] = row[threadIdx.x];
    for (int tid = 0; tid < cols; tid += blockDim.x) {
      int id = tid + threadIdx.x;
      if (id < cols) {
        float value = row[id];
        value *= srcMapping[ batchID[rowIdx] * srcNum + id ];
        if (value > _max[threadIdx.x]) {
          _max[threadIdx.x] = value;
        }
      }
    }

    int len = blockDim.x;
    while (len != 1) {
      __syncthreads();

      int skip = (len + 1) >> 1;
      if (threadIdx.x < (len >> 1)) {
        if(_max[threadIdx.x + skip] > _max[threadIdx.x])
          _max[threadIdx.x] = _max[threadIdx.x + skip];
      }
      len = (len + 1) >> 1;
    }
    __syncthreads();
    float max = _max[0];
    __syncthreads();

    float* _sum = _share;// + blockDim.x;
    _sum[threadIdx.x] = 0.0f;
    for (int tid = 0; tid < cols; tid += blockDim.x) {
      int id = tid + threadIdx.x;
      if (id < cols) {
        row[id] = __expf(row[id] - max);
        row[id] *= srcMapping[ batchID[rowIdx] * srcNum + id ];
        _sum[threadIdx.x] += row[id];
      }
    }

    __syncthreads();

    len = blockDim.x;
    while (len != 1) {
      __syncthreads();

      int skip = (len + 1) >> 1;
      if (threadIdx.x < (len >> 1)) {
        _sum[threadIdx.x] += _sum[threadIdx.x + skip];
      }
      len = (len + 1) >> 1;
    }

    __syncthreads();

    for (int tid = 0; tid < cols; tid += blockDim.x) {
      int id = tid + threadIdx.x;
      if (id < cols) {
        row[id] /= _sum[0];
      }
    }
    __syncthreads();
    rowIdx += gridDim.x;
  }
}

Matrix& Softmax(Matrix& Out, const DeviceVector<int>& batchIds, const DeviceVector<int>& srcMapping,size_t srcSize) {
  int blocks = std::min(MAX_BLOCKS, (int)Out.dim(0));
  int threads = std::min(MAX_THREADS, (int)Out.dim(1));
  int shared = sizeof(float) * threads * 2;

  gSoftMax<<<blocks, threads, shared, CudaStreamHandler::GetStream()>>>
    (Out.data(), Out.dim(0), Out.dim(1),
     thrust::raw_pointer_cast(batchIds.data()), batchIds.size(),
     thrust::raw_pointer_cast(srcMapping.data()), srcSize);
  return Out;
}

__global__ void gLogSoftMax(float* softMaxP, size_t rows, size_t cols) {
  extern __shared__ float _share[];

  int rowIdx =  blockIdx.x;

  while (rowIdx < rows) {
    float* row = softMaxP + rowIdx * cols;

    float* _max = _share;
    _max[threadIdx.x] = row[threadIdx.x];
    for (int tid = 0; tid < cols; tid += blockDim.x) {
      int id = tid + threadIdx.x;
      if (id < cols) {
        if (row[id] > _max[threadIdx.x]) {
          _max[threadIdx.x] = row[id];
        }
      }
    }

    int len = blockDim.x;
    while (len != 1) {
      __syncthreads();

      int skip = (len + 1) >> 1;
      if (threadIdx.x < (len >> 1)) {
        if(_max[threadIdx.x + skip] > _max[threadIdx.x])
          _max[threadIdx.x] = _max[threadIdx.x + skip];
      }
      len = (len + 1) >> 1;
    }
    __syncthreads();
    float max = _max[0];
    __syncthreads();

    float* _sum = _share;// + blockDim.x;

    _sum[threadIdx.x] = 0.0f;
    for (int tid = 0; tid < cols; tid += blockDim.x) {
      int id = tid + threadIdx.x;
      if (id < cols) {
        row[id] = __expf(row[id] - max);
        _sum[threadIdx.x] += row[id];
      }
    }

    len = blockDim.x;
    while (len != 1) {
      __syncthreads();

      int skip = (len + 1) >> 1;
      if (threadIdx.x < (len >> 1)) {
        _sum[threadIdx.x] += _sum[threadIdx.x + skip];
      }
      len = (len + 1) >> 1;
    }

    __syncthreads();

    for (int tid = 0; tid < cols; tid += blockDim.x) {
      int id = tid + threadIdx.x;
      if (id < cols) {
        row[id] = __logf(row[id]/_sum[0]);
      }
    }
    __syncthreads();
    rowIdx += gridDim.x;
  }
}


Matrix& LogSoftmax(Matrix& Out) {
  int blocks = std::min(MAX_BLOCKS, (int)Out.dim(0));
  int threads = std::min(MAX_THREADS, (int)Out.dim(1));
  int shared = sizeof(float) * threads * 2;

  gLogSoftMax<<<blocks, 500, shared, CudaStreamHandler::GetStream()>>>
    (Out.data(), Out.dim(0), Out.dim(1));

  return Out;
}

__global__ void gSetColumn(float* d_in, int n_columns, int n_rows, int noColumn, float value) {
  int rowNumber = threadIdx.x  + blockDim.x * blockIdx.x;
  int index = noColumn + rowNumber * n_columns;

  if (index < n_columns * n_rows) {
    d_in[index] = value;
  }
}

void SetColumn(Matrix& In, int noColumn, float value) {
  int nColumns = In.dim(1);
  int nRows = In.dim(0);
  int nBlocks = nRows / 512 + ((nRows % 512 == 0) ?  0 : 1);
  int nThreads = std::min(512, nRows);

  gSetColumn<<<nBlocks, nThreads, 0, mblas::CudaStreamHandler::GetStream()>>>
    (In.data(), nColumns, nRows, noColumn, value);
}

__global__ void gFill(float* d_in, int size, float val) {
  int index = threadIdx.x + blockDim.x * blockIdx.x;
  if (index < size) {
    d_in[index] = val;
  }
}

void Fill(Matrix& In, float value) {
  size_t size = In.size();
  int nThreads = std::min(512, (int)size);
  int nBlocks = (size / nThreads) + ((size % nThreads == 0) ? 0 : 1);

  gFill<<<nBlocks, nThreads, 0, CudaStreamHandler::GetStream()>>>
    (In.data(), size, value);
}

__global__
void gMapMatrix(float* d_in, int numRows, int numCols, int mappingCols, const int* mapping, int i) {
  int tid = threadIdx.x + blockIdx.x * blockDim.x;
  if (tid < numRows * numCols) {
    int batchIdx = tid / numCols;
    d_in[tid] *= mapping[mappingCols * batchIdx + i];
  }
}

void MapMatrix(Matrix& state, const DeviceVector<int>& mapping, size_t i) {
  int batchSize = state.dim(0);
  int stateLength = state.dim(1);
  int sentenceLength = mapping.size() / batchSize;

  int numThreads = std::min((int)state.size(), 512);
  int numBlocks = (state.size() / numThreads) + 1;

  float* d_in = state.data();
  const int* d_mapping = thrust::raw_pointer_cast(mapping.data());

  gMapMatrix<<<numBlocks, numThreads, 0, CudaStreamHandler::GetStream()>>>
    (d_in, batchSize, stateLength, sentenceLength, d_mapping, i);
}

__global__ void gLNormalization(float* out, const float* in, const float* alpha, const float* beta,
                                    int rows, int cols, float eps=0.00001) {
  extern __shared__ float _share[];

  for (int bid = 0; bid < rows; bid += gridDim.x) {
    int j = bid + blockIdx.x;
    if (j < rows) {
      float* so = out + j * cols;
      const float* sp = in + j * cols;

      float* _sum = _share + blockDim.x;
      _sum[threadIdx.x] = 0.0f;
      for (int tid = 0; tid < cols; tid += blockDim.x) {
        int id = tid + threadIdx.x;
        if (id < cols) {
          _sum[threadIdx.x] += sp[id];
        }
      }
      __syncthreads();
      int len = blockDim.x;
      while(len != 1) {
        __syncthreads();
        int skip = (len + 1) >> 1;
        if (threadIdx.x < (len >> 1)) {
          _sum[threadIdx.x] += _sum[threadIdx.x + skip];
        }
        len = (len + 1) >> 1;
      }
      __syncthreads();
      float mean = _sum[0] / cols;
      __syncthreads();

      float* _sqSum = _share + blockDim.x;

      _sqSum[threadIdx.x] = 0.0;
      for (int tid = 0; tid < cols; tid += blockDim.x) {
        int id = tid + threadIdx.x;
        if(id < cols) {
          float ex = sp[id] - mean;
          so[id] = ex;
          _sqSum[threadIdx.x] += ex * ex;
        }
      }
      __syncthreads();
      len = blockDim.x;
      while(len != 1) {
        __syncthreads();
        int skip = (len + 1) >> 1;
        if(threadIdx.x < (len >> 1))
          _sqSum[threadIdx.x] += _sqSum[threadIdx.x + skip];
        len = (len + 1) >> 1;
      }
      __syncthreads();
      float sigma = sqrtf(eps + (_sqSum[0] / cols));
      __syncthreads();

      for (int tid = 0; tid < cols; tid += blockDim.x) {
        int id = tid + threadIdx.x;
        if(id < cols) {
          if (beta != nullptr) {
            so[id] = alpha[id] * (so[id] / sigma) + beta[id];
          } else {
            so[id] = alpha[id] * (so[id] / sigma);
          }
        }
      }
    }
  }
}

void Normalization(Matrix& out, const Matrix& in, const Matrix& alpha, const Matrix& beta,
                       float eps) {
  int numThreads = std::min((int)in.dim(1), 512);

  out.Reshape(in.dim(0), in.dim(1), 1, 1);

  int rows = in.dim(0);
  int cols = in.dim(1);
  int numBlocks = std::min(rows, 65000);
  int shared = numThreads * sizeof(float) * 2;

  gLNormalization<<<numBlocks, numThreads, shared, CudaStreamHandler::GetStream()>>>
    (out.data(), in.data(), alpha.data(), beta.data(), rows, cols, eps);
}

void Normalization(Matrix& out, const Matrix& in, const Matrix& alpha, float eps) {
  int numThreads = std::min((int)in.dim(1), 512);

  out.Reshape(in.dim(0), in.dim(1), 1, 1);

  int rows = in.dim(0);
  int cols = in.dim(1);
  int numBlocks = std::min(rows, 65000);
  int shared = numThreads * sizeof(float) * 2;

  gLNormalization<<<numBlocks, numThreads, shared, CudaStreamHandler::GetStream()>>>
    (out.data(), in.data(), alpha.data(), nullptr, rows, cols, eps);
}

}  // namespace mblas
}  // namespace GPU
}  // namespace amunmt
