/*
 *  Copyright 2011 Chen-Hsiung Liu, Lung-Sheng Chien, Cheng-Hung Lin,and Shih-Chieh Chang
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */

/*
 *  F = number of final states, we label final states from s{1}, s{2}, ... s{F}
 *  and initial state is s{F+1}. s{0} is of no use.
 *
 *  if maximum pattern length is less than 512, then we will load transition function
 *  of initial state to shared memory, so we requires THREAD_BLOCK_SIZE = 256 such that
 *  each thread load one transition pair into shared memory 
 */

/*
 *  we know load unbalance is important in pattern matching
 *
 *  so far, kernel has 100% occupancy, 6 thread blocks, 256 threads per block.
 *  resource usage: 14 regs. 2560 Bytes smem
 *
 *  Remark 1: if we want to relax load unbalance, then 8 blocks is an option,
 *            say 8 x 192 = 1536 threads
 *
 *  Remark 2: if we can relax occupancy to 1024 threads /SM, then each thread can
 *            use 32 registers and each block can use 6KB smem.
 *            we can use 256 threads per block and 16 paths per thread or
 *                       128 threads per block and 16 paths per thread
 *
 */
 
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cuda_runtime.h>
#include <assert.h>
#include <ctype.h>
#include <stdarg.h>

#include "../include/PFAC_P.h"

#ifdef __cplusplus
extern "C" {
 
PFAC_status_t  PFAC_kernel_timeDriven_warpper( PFAC_handle_t handle, char *d_input_string, size_t input_size,
    int *d_matched_result) ;
} 
#endif // __cplusplus


#define THREAD_BLOCK_EXP   (8)
#define EXTRA_SIZE_PER_TB  (128)
#define THREAD_BLOCK_SIZE  (1 << THREAD_BLOCK_EXP)

#if THREAD_BLOCK_SIZE != 256 
    #error THREAD_BLOCK_SIZE != 256 
#endif

cudaTextureObject_t tex_PFAC_table;

void createTextureObject(cudaTextureObject_t &texObj, int *d_PFAC_table, size_t tableSize) {
    cudaResourceDesc resDesc = {};
    resDesc.resType = cudaResourceTypeLinear;
    resDesc.res.linear.devPtr = d_PFAC_table;
    resDesc.res.linear.sizeInBytes = tableSize;
    resDesc.res.linear.desc = cudaCreateChannelDesc<int>(); // Describes int data type

    cudaTextureDesc texDesc = {};
    texDesc.addressMode[0] = cudaAddressModeClamp; // Addressing mode
    texDesc.filterMode = cudaFilterModePoint;      // No interpolation
    texDesc.readMode = cudaReadModeElementType;    // Read as element type
    texDesc.normalizedCoords = 0;                  // Use unnormalized coordinates

    cudaCreateTextureObject(&texObj, &resDesc, &texDesc, nullptr);
}

void destroyTextureObject(cudaTextureObject_t &texObj) {
    cudaDestroyTextureObject(texObj);
}

__device__ int tex_lookup(cudaTextureObject_t texObj, int state, int inputChar) {
    return tex1Dfetch<int>(texObj, state * CHAR_SET + inputChar);
}

template <int BLOCKSIZE, int EXTRA_SIZE_TB, int TEXTURE_ON , int SMEM_ON >
__global__ void PFAC_kernel_timeDriven(
    int *d_PFAC_table, 
    int *d_input_string, 
    int input_size,
    int n_hat, 
    int num_finalState, 
    int initial_state, 
    int num_blocks_minus1,
    int *d_match_result,
    cudaTextureObject_t texObj);
   
//------------------- main function -----------------------

/* time-driven kernel */
__host__ PFAC_status_t PFAC_kernel_timeDriven_warpper(
    PFAC_handle_t handle,
    char *d_input_string,
    size_t input_size,
    int *d_matched_result) {
    cudaError_t cuda_status;
    PFAC_status_t pfac_status = PFAC_STATUS_SUCCESS;

    int num_finalState = handle->numOfFinalStates;
    int initial_state = handle->initial_state;

    bool smem_on = ((4 * EXTRA_SIZE_PER_TB - 1) >= handle->maxPatternLen);
    bool texture_on = (PFAC_TEXTURE_ON == handle->textureMode);

    PFAC_PRINTF("texture on = %d\n", texture_on);

    if (texture_on) {
        createTextureObject(tex_PFAC_table, handle->d_PFAC_table, handle->sizeOfTableInBytes);
    }

    // Compute grid and block dimensions
    int n_hat = (input_size + sizeof(int) - 1) / sizeof(int);
    int num_blocks = (n_hat + THREAD_BLOCK_SIZE - 1) / THREAD_BLOCK_SIZE;
    dim3 dimBlock(THREAD_BLOCK_SIZE, 1);
    dim3 dimGrid;

    int p = num_blocks >> 15;
    dimGrid.x = num_blocks;
    if (p) {
        dimGrid.x = 1 << 15;
        dimGrid.y = p + 1;
    }

    if (smem_on) {
        if (texture_on) {
            PFAC_PRINTF("PFAC_kernel_timeDriven, tex on, smem on\n");
            PFAC_kernel_timeDriven<THREAD_BLOCK_SIZE, EXTRA_SIZE_PER_TB, 1, 1>
                <<<dimGrid, dimBlock>>>(
                    handle->d_PFAC_table, 
                    (int *)d_input_string, 
                    input_size, 
                    n_hat, 
                    num_finalState, 
                    initial_state, 
                    num_blocks - 1, 
                    d_matched_result, 
                    tex_PFAC_table // Pass texture object
                );
        } else {
            PFAC_PRINTF("PFAC_kernel_timeDriven, tex off, smem on\n");
            PFAC_kernel_timeDriven<THREAD_BLOCK_SIZE, EXTRA_SIZE_PER_TB, 0, 1>
                <<<dimGrid, dimBlock>>>(
                    handle->d_PFAC_table, 
                    (int *)d_input_string, 
                    input_size, 
                    n_hat, 
                    num_finalState, 
                    initial_state, 
                    num_blocks - 1, 
                    d_matched_result, 
                    tex_PFAC_table // No texture object
                );
        }
    } else {
        if (texture_on) {
            PFAC_PRINTF("PFAC_kernel_timeDriven, tex on, smem off\n");
            PFAC_kernel_timeDriven<THREAD_BLOCK_SIZE, EXTRA_SIZE_PER_TB, 1, 0>
                <<<dimGrid, dimBlock>>>(
                    handle->d_PFAC_table, 
                    (int *)d_input_string, 
                    input_size, 
                    n_hat, 
                    num_finalState, 
                    initial_state, 
                    num_blocks - 1, 
                    d_matched_result, 
                    tex_PFAC_table // Pass texture object
                );
        } else {
            PFAC_PRINTF("PFAC_kernel_timeDriven, tex off, smem off\n");
            PFAC_kernel_timeDriven<THREAD_BLOCK_SIZE, EXTRA_SIZE_PER_TB, 0, 0>
                <<<dimGrid, dimBlock>>>(
                    handle->d_PFAC_table, 
                    (int *)d_input_string, 
                    input_size, 
                    n_hat, 
                    num_finalState, 
                    initial_state, 
                    num_blocks - 1, 
                    d_matched_result, 
                    tex_PFAC_table // No texture object
                );
        }
    }



    cuda_status = cudaGetLastError();

    if (texture_on) {
        destroyTextureObject(tex_PFAC_table);
    }

    if (cudaSuccess != cuda_status) {
        return PFAC_STATUS_INTERNAL_ERROR;
    }

    return PFAC_STATUS_SUCCESS;
}



/*
 *  (1) transition table of initial state is in the shared memory phi_s02s1
 *      we don't need to look up table in texture tex_PFAC_table
 *
 *  (2) final states are reordered as 1, 2, ..., k
 *      so state number <= k (number of final states) means final state
 */
#define SUBSEG_MATCH(j, match) \
    pos = tid + j * BLOCKSIZE; \
    if (pos < bdy) { \
        inputChar = s_char[pos]; \
        state = phi_s02s1[inputChar]; \
        if (TRAP_STATE != state) { \
            if (state <= num_finalState) { \
                match = state; \
            } \
            pos = pos + 1; \
            while (pos < bdy) { \
                inputChar = s_char[pos]; \
                state = tex_lookup(texObj, state, inputChar); \
                if (TRAP_STATE == state) { \
                    break; \
                } \
                if (state <= num_finalState) { \
                    match = state; \
                } \
                pos = pos + 1; \
            } \
        } \
    }

// end macro

#define  SUBSEG_MATCH_NOTEX( j, match ) \
    pos = tid + j * BLOCKSIZE ;\
    if ( pos < bdy ){ \
        inputChar = s_char[pos]; \
        state = phi_s02s1[ inputChar ]; \
        if ( TRAP_STATE != state ){ \
            if ( state <= num_finalState ){ \
                match = state;\
            } \
            pos = pos + 1; \
            while ( pos < bdy ) { \
                inputChar = s_char[pos]; \
                state = *(d_PFAC_table + state*CHAR_SET + inputChar); \
                if ( TRAP_STATE == state ){ break ;} \
                if ( state <= num_finalState ){ \
                    match = state;\
                }\
                pos = pos + 1;\
            }\
        }\
    }
// end macro

#define SUBSEG_MATCH_NOSMEM(j, match) \
    pos = (gbid * BLOCKSIZE * 4) + tid + j * BLOCKSIZE; \
    if (pos < input_size) { \
        inputChar = (unsigned char)char_d_input_string[pos]; \
        state = phi_s02s1[inputChar]; \
        if (TRAP_STATE != state) { \
            if (state <= num_finalState) { \
                match = state; \
            } \
            pos = pos + 1; \
            while (pos < input_size) { \
                inputChar = (unsigned char)char_d_input_string[pos]; \
                state = tex_lookup(texObj, state, inputChar); \
                if (TRAP_STATE == state) { \
                    break; \
                } \
                if (state <= num_finalState) { \
                    match = state; \
                } \
                pos = pos + 1; \
            } \
        } \
    }

// end macro

#define  SUBSEG_MATCH_NOSMEM_NOTEX( j, match ) \
    pos = ( gbid * BLOCKSIZE * 4 ) + tid + j * BLOCKSIZE ;\
    if ( pos < input_size ){ \
        inputChar = (unsigned char) char_d_input_string[pos]; \
        state = phi_s02s1[ inputChar ]; \
        if ( TRAP_STATE != state ){ \
            if ( state <= num_finalState ){ \
                match = state;\
            } \
            pos = pos + 1; \
            while ( pos < input_size ) { \
                inputChar = (unsigned char) char_d_input_string[pos]; \
                state = *(d_PFAC_table + state*CHAR_SET + inputChar); \
                if ( TRAP_STATE == state ){ break ;} \
                if ( state <= num_finalState ){ \
                    match = state;\
                }\
                pos = pos + 1;\
            }\
        }\
    }
// end macro


#define MANUAL_EXPAND_2( X )   { X ; X ; }
#define MANUAL_EXPAND_4( X )   { MANUAL_EXPAND_2( MANUAL_EXPAND_2( X ) )  }

/*
 *  each thread loads one integer (32-bit) to shared memory s_input[ BLOCKSIZE + EXTRA_SIZE_TB]
 *  also read extra size of this thread block
 *
 *  Example: thread block = 256 and extra size = 128, then each thread read twice
 *      if ( start < n_hat ){
 *          s_input[tid] = d_input_string[start];
 *      }
 *      start += BLOCKSIZE ;
 *      if ( (start < n_hat) && (tid < EXTRA_SIZE_TB) ){
 *           s_input[tid+BLOCKSIZE] = d_input_string[start];
 *      }
 *      __syncthreads();
 *
 *  in general, EXTRA_SIZE_TB may not be BLOCKSIZE/2
 *
 *
 *  occupancy
 *
 *  sm_20:
 *     Used 15 registers, 1024+0 bytes smem, 80 bytes cmem[0] => 1536 threads per SM 
 *      
 *  sm_13:
 *     Used 13 registers, 1072+16 bytes smem, 4 bytes cmem[1] => 1024 threads per SM 
 *
 */
template <int BLOCKSIZE, int EXTRA_SIZE_TB, int TEXTURE_ON, int SMEM_ON>
__global__ void PFAC_kernel_timeDriven(
    int *d_PFAC_table,
    int *d_input_string,
    int input_size, // size_t matches the invocation
    int n_hat,
    int num_finalState,
    int initial_state,
    int num_blocks_minus1,
    int *d_match_result,
    cudaTextureObject_t texObj // Consistently typed for texture object
) {

    int tid = threadIdx.x;
    int gbid = blockIdx.y * gridDim.x + blockIdx.x;
    int start = gbid * BLOCKSIZE + tid;
    int pos;
    int state;
    int inputChar;
    int match[4] = {0, 0, 0, 0};
    __shared__ int s_input[BLOCKSIZE + EXTRA_SIZE_TB];
    __shared__ int phi_s02s1[256];
    volatile unsigned char *s_char;
    char *char_d_input_string;

    if (gbid > num_blocks_minus1) {
        return;
    }

    if (TEXTURE_ON) {
        phi_s02s1[tid] = tex_lookup(texObj, initial_state, tid);
    } else {
        phi_s02s1[tid] = *(d_PFAC_table + initial_state * CHAR_SET + tid);
    }

    if (SMEM_ON) {
        s_char = (unsigned char *)s_input;

        if (start < n_hat) {
            s_input[tid] = d_input_string[start];
        }
        start += BLOCKSIZE;
        if ((start < n_hat) && (tid < EXTRA_SIZE_TB)) {
            s_input[tid + BLOCKSIZE] = d_input_string[start];
        }
    }

    __syncthreads();

    int bdy = input_size - (gbid * BLOCKSIZE * 4);

    if (SMEM_ON) {
        if (TEXTURE_ON) {
            int j = 0;
            MANUAL_EXPAND_4(SUBSEG_MATCH(j, match[j]); j++;)
        } else {
            int j = 0;
            MANUAL_EXPAND_4(SUBSEG_MATCH_NOTEX(j, match[j]); j++;)
        }
    } else {
        char_d_input_string = (char *)d_input_string;
        if (TEXTURE_ON) {
            int j = 0;
            MANUAL_EXPAND_4(SUBSEG_MATCH_NOSMEM(j, match[j]); j++;)
        } else {
            int j = 0;
            MANUAL_EXPAND_4(SUBSEG_MATCH_NOSMEM_NOTEX(j, match[j]); j++;)
        }
    }

    start = gbid * (BLOCKSIZE * 4) + tid;

    if (gbid < num_blocks_minus1) {
        #pragma unroll
        for (int j = 0; j < 4; j++) {
            d_match_result[start] = match[j];
            start += BLOCKSIZE;
        }
    } else {
        int j = 0;
        MANUAL_EXPAND_4(if (start >= input_size) return; d_match_result[start] = match[j]; j++; start += BLOCKSIZE;)
    }
}

