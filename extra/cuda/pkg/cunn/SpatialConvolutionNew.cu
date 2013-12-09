#ifndef assert
#define assert(e)  \
    if (!(e)) { \
        printf("failed assertion `%s'\n", #e); \
        THError("aborting..."); \
    };
#endif


__global__ void copyPixelsInSlices(float *ptrinput, float *ptrkslices,
	int dH, int dW, int kH, int kW, int size1, int size2, int isize1, int isize2, int nInputPlane, int valuesperthread, int padleft, int padright, int padup, int paddown)
{
	const int pixi=blockIdx.x;
	const int pixj=blockIdx.y;
	const int blk =blockDim.x;
	const int tidx=threadIdx.x;

        int imin=(pixi - (kH - 1) + (dH -1))/dH > 0 ? (pixi - (kH - 1) + (dH -1))/dH : 0 ;
        int jmin=(pixj - (kW - 1) + (dW -1))/dW > 0 ? (pixj - (kW - 1) + (dW -1))/dW : 0 ;
        int imax= pixi / dH < size1 ? pixi / dH : size1 - 1 ;
        int jmax= pixj / dW < size2 ? pixj / dW : size2 - 1 ;

	int i;
	int j;
	int k;

	bool zeropad=pixi<padup || pixi>isize1-1+padup || pixj<padleft || pixj>isize2-1+padleft ;
	
	ptrinput   += ((pixi-padup) * isize2 + (pixj-padleft)) * nInputPlane ;
	ptrkslices += ((imin * size2  + jmin) * kH * kW +  (pixi - imin * dH) * kW + (pixj - jmin*dW) ) * nInputPlane;

	int stridej = (kH*kW - dW) * nInputPlane;
	int stridei = (((size2-jmax+jmin-1)*kH -dH)*kW  + (jmax-jmin+1)*dW)*nInputPlane;
	
	if(tidx<nInputPlane) {
		for(i=imin; i<imax+1; i++) {
			for(j=jmin; j<jmax+1; j++) {
				if(zeropad) 
				{
					for(k=0; k<valuesperthread; k++) {
						ptrkslices[k*blk+tidx]=0;
					}
				}
				else {
					for(k=0; k<valuesperthread; k++) {
						ptrkslices[k*blk+tidx]=ptrinput[k*blk+tidx];
					}
				}
				ptrkslices += stridej;
			}
			ptrkslices += stridei;
		}	
	}
}


__global__ void addPixelsInSlices(float *ptrgradinput, float *ptrkslices,
	int dH, int dW, int kH, int kW, int size1, int size2, int isize1, int isize2, int nInputPlane, int valuesperthread, int padleft, int padright, int padup, int paddown)
{
	const int pixi=blockIdx.x;
	const int pixj=blockIdx.y;
	const int blk =blockDim.x;
	const int tidx=threadIdx.x;

        int imin=(pixi - (kH - 1) + (dH -1))/dH > 0 ? (pixi - (kH - 1) + (dH -1))/dH : 0 ;
        int jmin=(pixj - (kW - 1) + (dW -1))/dW > 0 ? (pixj - (kW - 1) + (dW -1))/dW : 0 ;
        int imax= pixi / dH < size1 ? pixi / dH : size1 - 1 ;
        int jmax= pixj / dW < size2 ? pixj / dW : size2 - 1 ;

	int i;
	int j;
	int k;

	bool zeropad=pixi<padup || pixi>isize1-1+padup || pixj<padleft || pixj>isize2-1+padleft ;
	
	ptrgradinput += ((pixi-padup) * isize2 + (pixj-padleft)) * nInputPlane ;
	ptrkslices   += ((imin * size2  + jmin) * kH * kW +  (pixi - imin * dH) * kW + (pixj - jmin*dW) ) * nInputPlane;

	int stridej = (kH*kW - dW) * nInputPlane;
	int stridei = (((size2-jmax+jmin-1)*kH -dH)*kW  + (jmax-jmin+1)*dW)*nInputPlane;

	for(k=0; k<valuesperthread; k++) {
		ptrgradinput[k*blk+tidx] = 0;
	}
	
	if(tidx<nInputPlane) {
		if(!zeropad) {
			for(i=imin; i<imax+1; i++) {
				for(j=jmin; j<jmax+1; j++) {
						for(k=0; k<valuesperthread; k++) {
							ptrgradinput[k*blk+tidx] += ptrkslices[k*blk+tidx];
						}
					ptrkslices += stridej;
				}
				ptrkslices += stridei;
			}	
		}
	}
}


template <int maxnumplanes> __global__ void addPixelsInSlicesSharedMem(float *ptrgradinput, float *ptrkslices,
	int dH, int dW, int kH, int kW, int size1, int size2, int isize1, int isize2, int nInputPlane, int valuesperthread, int padleft, int padright, int padup, int paddown)
{
	const int pixi=blockIdx.x;
	const int pixj=blockIdx.y;
	const int blk =blockDim.x;
	const int tidx=threadIdx.x;

        int imin=(pixi - (kH - 1) + (dH -1))/dH > 0 ? (pixi - (kH - 1) + (dH -1))/dH : 0 ;
        int jmin=(pixj - (kW - 1) + (dW -1))/dW > 0 ? (pixj - (kW - 1) + (dW -1))/dW : 0 ;
        int imax= pixi / dH < size1 ? pixi / dH : size1 - 1 ;
        int jmax= pixj / dW < size2 ? pixj / dW : size2 - 1 ;

	int i;
	int j;
	int k;

	__shared__ float gradvalues[maxnumplanes];
		for(k=0; k<valuesperthread; k++) {
			gradvalues[k*blk+tidx]=0;
		}

	bool zeropad=pixi<padup || pixi>isize1-1+padup || pixj<padleft || pixj>isize2-1+padleft ;
	
	ptrgradinput += ((pixi-padup) * isize2 + (pixj-padleft)) * nInputPlane ;
	ptrkslices   += ((imin * size2  + jmin) * kH * kW +  (pixi - imin * dH) * kW + (pixj - jmin*dW) ) * nInputPlane;

	int stridej = (kH*kW - dW) * nInputPlane;
	int stridei = (((size2-jmax+jmin-1)*kH -dH)*kW  + (jmax-jmin+1)*dW)*nInputPlane;

	if(tidx<nInputPlane) {
		if(!zeropad) {
			for(i=imin; i<imax+1; i++) {
				for(j=jmin; j<jmax+1; j++) {
					for(k=0; k<valuesperthread; k++) {
						gradvalues[k*blk+tidx] += ptrkslices[k*blk+tidx];
					}
				ptrkslices += stridej;
				}
				ptrkslices += stridei;
			}	
			for(k=0; k<valuesperthread; k++) {
				ptrgradinput[k*blk+tidx] = gradvalues[k*blk+tidx];
			}
		}
	}
}


template <int maxnumplanes> __global__ void copyPixelsInSlicesSharedMem(float *ptrinput, float *ptrkslices,
	int dH, int dW, int kH, int kW, int size1, int size2, int isize1, int isize2, int nInputPlane, int valuesperthread, int padleft, int padright, int padup, int paddown)
{
	// each block does one pixel of the input image
	// each kernel slice is represented by its upper-left coordinates

	const int pixi=blockIdx.x;
	const int pixj=blockIdx.y;
	const int blk =blockDim.x;
	const int tidx=threadIdx.x;

	int i,j,k;



	// step 1 : find which kernel slices contain the values of the pixel
        const int imin=(pixi - (kH - 1) + (dH -1))/dH > 0 ? (pixi - (kH - 1) + (dH -1))/dH : 0 ;
        const int jmin=(pixj - (kW - 1) + (dW -1))/dW > 0 ? (pixj - (kW - 1) + (dW -1))/dW : 0 ;
        const int imax= pixi / dH < size1 ? pixi / dH : size1 - 1 ;
        const int jmax= pixj / dW < size2 ? pixj / dW : size2 - 1 ;

	// step 2 : move the pointers
	// this one goes to where the pixel is at
	ptrinput   += ((pixi-padup) * isize2 + (pixj-padleft)) * nInputPlane ;
	// this one goes to the first pixel of the first kernel slice
	ptrkslices += ((imin * size2  + jmin) * kH * kW +  (pixi - imin * dH) * kW + (pixj - jmin*dW) ) * nInputPlane;

	bool zeropad = pixi<padup || pixi>isize1-1+padup || pixj<padleft || pixj>isize2-1+padleft ;
	// read pixel
	// load the stuff in shared memory first...
	__shared__ float pixvalues[maxnumplanes];
	if(tidx<nInputPlane) {
		if (zeropad) 
		{
			for(k=0; k<valuesperthread; k++) {
				pixvalues[k*blk+tidx]=0;
			}
		}
		else
		{
			for(k=0; k<valuesperthread; k++) {
				pixvalues[k*blk+tidx]=ptrinput[k*blk+tidx];
			}
		}
	}

	int stridej = (kH*kW - dW) * nInputPlane;
//	int stridei = (((size2-jmax+jmin-1)*kH -dH)*kW  + (jmax-jmin+1)*dW)*nInputPlane;
	int stridei = (size2*kH-dH) * kW *nInputPlane - (jmax-jmin+1) * stridej ;

//	write to memory
	if(tidx<nInputPlane) {
		for(i=imin; i<imax+1; i++) {
			for(j=jmin; j<jmax+1; j++) {
				if(zeropad) 
				{
					for(k=0; k<valuesperthread; k++) {
						ptrkslices[k*blk+tidx]=0;
					}
				}
				else {
					for(k=0; k<valuesperthread; k++) {
						ptrkslices[k*blk+tidx]=pixvalues[k*blk+tidx];
					}
				}
				ptrkslices += stridej;
			}
			ptrkslices += stridei;
		}	
	}
}


__global__ void copyBiasToOutputs(float *ptrbias, float *ptroutput, const int size1, const int size2, const int nOutputPlane)
{
	// each thread has a value to manage...
	//const int blk =blockDim.x;
	const int tidx=blockDim.x*blockIdx.x + threadIdx.x;
	const int numpix=size1*size2;

	int i;

	float val = ptrbias[tidx];

	for(i=0; i<numpix; i++) {
		ptroutput[tidx]=val;
		ptroutput+=nOutputPlane;
	}
}





__global__ void computeGradBias(float *ptrgradbias, float *ptrgradoutput, const int size1, const int size2, const int nOutputPlane, bool add)
{
	// each thread does one plane
	const int tidx=blockDim.x*blockIdx.x + threadIdx.x;
	const int numpix=size1*size2;

	float value = 0;
	int i;

	for(i=0; i<numpix; i++) {
		value += ptrgradoutput[tidx];
		ptrgradoutput+=nOutputPlane;
	}

	if(add) {	
	ptrgradbias[tidx]+=value;
	} else {
	ptrgradbias[tidx]=value; 
	}

}




static int cunn_SpatialConvolutionNew_updateOutput(lua_State *L)
{
  THCudaTensor *input = (THCudaTensor *)luaT_checkudata(L, 2, "torch.CudaTensor");
  THCudaTensor *output = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "output", "torch.CudaTensor");
  THCudaTensor *kernels = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "weight", "torch.CudaTensor");
  THCudaTensor *bias = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "bias", "torch.CudaTensor");
  THCudaTensor *kernelSlices = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "kernelSlices", "torch.CudaTensor");
  long kW = luaT_getfieldcheckint(L, 1, "kW");
  long kH = luaT_getfieldcheckint(L, 1, "kH");
  long dW = luaT_getfieldcheckint(L, 1, "dW");
  long dH = luaT_getfieldcheckint(L, 1, "dH");
  long padup = luaT_getfieldcheckint(L, 1, "padup");
  long paddown = luaT_getfieldcheckint(L, 1, "paddown");
  long padleft = luaT_getfieldcheckint(L, 1, "padleft");
  long padright = luaT_getfieldcheckint(L, 1, "padright");
  long shdmem = luaT_getfieldcheckint(L, 1, "shdmem");
  long nOutputPlane = luaT_getfieldcheckint(L, 1, "nOutputPlane");
  long nInputPlane = luaT_getfieldcheckint(L, 1, "nInputPlane");

  //luaL_argcheck(L, dimension >= 0 && dimension < input->nDimension, 2, "dimension out of range");

  assert(nInputPlane%32 == 0 || nInputPlane<32);
  assert(nOutputPlane%32 == 0);


  // input should be contiguous already but... well.
  input = THCudaTensor_newContiguous(input);

  // find the size of kernelslices
  long isize1 = input->size[0];
  long isize2 = input->size[1];
  long size1 = (isize1 - kH + padup + paddown) / dH + 1;
  long size2 = (isize2 - kW + padleft + padright) / dW + 1;

//  THCudaTensor* kernelSlices = THCudaTensor_newWithSize1d(size1*size2*kW*kH*nInputPlane);
  THCudaTensor_resize1d(kernelSlices, size1*size2*kW*kH*nInputPlane);
  THCudaTensor_resize2d(output, size1* size2, nOutputPlane);

  float* ptrkslices = THCudaTensor_data(kernelSlices);
  float* ptroutput  = THCudaTensor_data(output);
  float* ptrinput   = THCudaTensor_data(input);
  float* ptrbias    = THCudaTensor_data(bias);


  // cuda blocks & threads:
  dim3 blocks (isize1 + padup + paddown, isize2 + padleft + padright);
  dim3 threads (32);
  long valuesperthread=nInputPlane/32;
  if(valuesperthread==0) { valuesperthread=1; } 

	  //kernel unfold inputs
	  if (nInputPlane >1024 || shdmem==0) {
	  copyPixelsInSlices<<<blocks, threads>>>(ptrinput, ptrkslices,
		dH, dW, kH, kW, size1, size2, isize1, isize2, nInputPlane, valuesperthread, padleft, padright, padup, paddown);
	  }
	  else if (nInputPlane >512) {
		//printf("using shared memory 1024 floats\n");
		copyPixelsInSlicesSharedMem <1024> <<<blocks, threads>>>(ptrinput, ptrkslices,
		dH, dW, kH, kW, size1, size2, isize1, isize2, nInputPlane, valuesperthread, padleft, padright, padup, paddown);
	  }
	  else if (nInputPlane >384) {
		//printf("using shared memory 512 floats\n");
		copyPixelsInSlicesSharedMem <512> <<<blocks, threads>>>(ptrinput, ptrkslices,
		dH, dW, kH, kW, size1, size2, isize1, isize2, nInputPlane, valuesperthread, padleft, padright, padup, paddown);
	  }
	  else if (nInputPlane >256) {
		//printf("using shared memory 384 floats\n");
		copyPixelsInSlicesSharedMem <384> <<<blocks, threads>>>(ptrinput, ptrkslices,
		dH, dW, kH, kW, size1, size2, isize1, isize2, nInputPlane, valuesperthread, padleft, padright, padup, paddown);
	  }
	  else if (nInputPlane >128) {
		//printf("using shared memory 256 floats\n");
		copyPixelsInSlicesSharedMem <256> <<<blocks, threads>>>(ptrinput, ptrkslices,
		dH, dW, kH, kW, size1, size2, isize1, isize2, nInputPlane, valuesperthread, padleft, padright, padup, paddown);
	  }
	  else if (nInputPlane >32) {
		//printf("using shared memory 256 floats\n");
		copyPixelsInSlicesSharedMem <128> <<<blocks, threads>>>(ptrinput, ptrkslices,
		dH, dW, kH, kW, size1, size2, isize1, isize2, nInputPlane, valuesperthread, padleft, padright, padup, paddown);
	  }
	  else {
		//printf("using shared memory 128 floats\n");
		copyPixelsInSlicesSharedMem <32> <<<blocks, threads>>>(ptrinput, ptrkslices,
		dH, dW, kH, kW, size1, size2, isize1, isize2, nInputPlane, 1, padleft, padright, padup, paddown);
	  }

  THCudaTensor_free(input); 



  // fill output with biases
  dim3 blocksbias (nOutputPlane/32);
  dim3 threadsbias (32);
  copyBiasToOutputs<<<blocksbias, threadsbias>>>(ptrbias, ptroutput, size1, size2, nOutputPlane); 



  // unfold conv kernels by resizing
  THCudaTensor_resize2d(kernels, nOutputPlane, kW*kH*nInputPlane);
  THCudaTensor_transpose(kernels, NULL, 0, 1);
  // put kernelslices in matrix mode
  THCudaTensor_resize2d(kernelSlices, size1*size2,kW*kH*nInputPlane);

//  printf("sgemm\n");
  // do addmm on output
  THCudaTensor_addmm(output, 1,1, kernelSlices, kernels);
//  printf("sgemm end\n");
//  THCudaTensor_free(kernelSlices); 
  THCudaTensor_transpose(kernels, NULL, 0, 1);


  // check for errors
  cudaError_t err = cudaGetLastError();
  if (err != cudaSuccess) {
    printf("error in copyPixelsInSlices: %s\n", cudaGetErrorString(err));
    THError("aborting");
  }

  THCudaTensor_resize3d(output, size1, size2, nOutputPlane);
 
//  THCudaTensor_resizeAs(kslicestest, kernelSlices);
//  THCudaTensor_copy(kslicestest, kernelSlices);

  // final cut:
  //THCudaTensor_select(output, NULL, dimension, 0);

  return 1;
}





static int cunn_SpatialConvolutionNew_updateGradInput(lua_State *L)
{
  THCudaTensor *input = (THCudaTensor *)luaT_checkudata(L, 2, "torch.CudaTensor");
  THCudaTensor *gradOutput = (THCudaTensor *)luaT_checkudata(L, 3, "torch.CudaTensor");
  long kW = luaT_getfieldcheckint(L, 1, "kW");
  long kH = luaT_getfieldcheckint(L, 1, "kH");
  long dW = luaT_getfieldcheckint(L, 1, "dW");
  long dH = luaT_getfieldcheckint(L, 1, "dH");
  long padup = luaT_getfieldcheckint(L, 1, "padup");
  long paddown = luaT_getfieldcheckint(L, 1, "paddown");
  long padleft = luaT_getfieldcheckint(L, 1, "padleft");
  long padright = luaT_getfieldcheckint(L, 1, "padright");
  long shdmem = luaT_getfieldcheckint(L, 1, "shdmem");
  long nOutputPlane = luaT_getfieldcheckint(L, 1, "nOutputPlane");
  long nInputPlane = luaT_getfieldcheckint(L, 1, "nInputPlane");
  long zeroGradients = luaT_getfieldcheckint(L, 1, "zeroGradients");

  THCudaTensor *kernelSlices = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "kernelSlices", "torch.CudaTensor");

  THCudaTensor *kernels = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "weight", "torch.CudaTensor");
  THCudaTensor *gradInput = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "gradInput", "torch.CudaTensor");
  THCudaTensor *gradWeight = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "gradWeight", "torch.CudaTensor");
  THCudaTensor *gradBias = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "gradBias", "torch.CudaTensor");



  long isize1 = input->size[0];
  long isize2 = input->size[1];
  long size1 = gradOutput->size[0];
  long size2 = gradOutput->size[1];

  THCudaTensor_resize2d(gradOutput, size1* size2, nOutputPlane);

// we compute gradWeight before gradInput because 
// we want to recycle the kernelSlices matrix
// and gradWeight actually needs it for its gradient.
// so by the way we compute gradbias too...  

  float* ptrgradbias = THCudaTensor_data(gradBias);
  float* ptrgradoutput  = THCudaTensor_data(gradOutput);
  dim3 blocksgradbias (nOutputPlane/32);
  dim3 threadsgradbias (32);

  THCudaTensor_resize2d(gradWeight, nOutputPlane, kW*kH*nInputPlane);
//  THCudaTensor_transpose(gradWeight, NULL, 0, 1);
  THCudaTensor_transpose(gradOutput, NULL, 0, 1);
  if (zeroGradients == 1) { 
	THCudaTensor_addmm(gradWeight, 0, 1, gradOutput, kernelSlices); 
	computeGradBias <<<blocksgradbias, threadsgradbias>>>  (ptrgradbias, ptrgradoutput, size1, size2, nOutputPlane, 0);
  } else {
	THCudaTensor_addmm(gradWeight, 1, 1, gradOutput, kernelSlices); 
	computeGradBias <<<blocksgradbias, threadsgradbias>>>  (ptrgradbias, ptrgradoutput, size1, size2, nOutputPlane, 1);
  }  
  THCudaTensor_transpose(gradOutput, NULL, 0, 1);
//  THCudaTensor_transpose(gradWeight, NULL, 0, 1);



// backprop gradinput into the slices
  THCudaTensor_addmm(kernelSlices, 0, 1, gradOutput, kernels);


// we resize gradOutput back to what it was...
  THCudaTensor_resize3d(gradOutput, size1, size2, nOutputPlane);




  THCudaTensor_resizeAs(gradInput, input);

  float* ptrkslices = THCudaTensor_data(kernelSlices);
  float* ptrgradinput  = THCudaTensor_data(gradInput);

  dim3 blocks (isize1 + padup + paddown, isize2 + padleft + padright);
  dim3 threads (32);
  long valuesperthread=nInputPlane/32;

  if(valuesperthread==0) { valuesperthread=1; } 
  // this is for the specific case of the inputs with less than 32 channels
  // for some reason i thought it would be cool to be able to backprop through it

	  if (nInputPlane >1024 || shdmem==0) {
	  addPixelsInSlices<<<blocks, threads>>>(ptrgradinput, ptrkslices,
		dH, dW, kH, kW, size1, size2, isize1, isize2, nInputPlane, valuesperthread, padleft, padright, padup, paddown);
	  }
	  else if (nInputPlane >512)  {
		//printf("using shared memory 1024 floats\n");
	  addPixelsInSlicesSharedMem <1024> <<<blocks, threads>>>(ptrgradinput, ptrkslices,
		dH, dW, kH, kW, size1, size2, isize1, isize2, nInputPlane, valuesperthread, padleft, padright, padup, paddown);
	  } 
	  else if (nInputPlane >384)  {
		//printf("using shared memory 1024 floats\n");
	  addPixelsInSlicesSharedMem <512> <<<blocks, threads>>>(ptrgradinput, ptrkslices,
		dH, dW, kH, kW, size1, size2, isize1, isize2, nInputPlane, valuesperthread, padleft, padright, padup, paddown);
	  } 
	  else if (nInputPlane >256)  {
		//printf("using shared memory 1024 floats\n");
	  addPixelsInSlicesSharedMem <384> <<<blocks, threads>>>(ptrgradinput, ptrkslices,
		dH, dW, kH, kW, size1, size2, isize1, isize2, nInputPlane, valuesperthread, padleft, padright, padup, paddown);
	  } 
	  else if (nInputPlane >128)  {
		//printf("using shared memory 1024 floats\n");
	  addPixelsInSlicesSharedMem <256> <<<blocks, threads>>>(ptrgradinput, ptrkslices,
		dH, dW, kH, kW, size1, size2, isize1, isize2, nInputPlane, valuesperthread, padleft, padright, padup, paddown);
	  } 
	  else if (nInputPlane >32)  {
		//printf("using shared memory 1024 floats\n");
	  addPixelsInSlicesSharedMem <128> <<<blocks, threads>>>(ptrgradinput, ptrkslices,
		dH, dW, kH, kW, size1, size2, isize1, isize2, nInputPlane, valuesperthread, padleft, padright, padup, paddown);
	  } 
	  else {
		//printf("using shared memory 1024 floats\n");
	  addPixelsInSlicesSharedMem <32> <<<blocks, threads>>>(ptrgradinput, ptrkslices,
		dH, dW, kH, kW, size1, size2, isize1, isize2, nInputPlane, valuesperthread, padleft, padright, padup, paddown);
	  } 






  return 1;
}



static int cunn_SpatialConvolutionNew_accGradParameters(lua_State *L)
{
  THCudaTensor *input = (THCudaTensor *)luaT_checkudata(L, 2, "torch.CudaTensor");
  THCudaTensor *gradOutput = (THCudaTensor *)luaT_checkudata(L, 3, "torch.CudaTensor");
  int dW = luaT_getfieldcheckint(L, 1, "dW");
  int dH = luaT_getfieldcheckint(L, 1, "dH");
  int nOutputPlane = luaT_getfieldcheckint(L, 1, "nOutputPlane");
  float scale = luaL_optnumber(L, 4, 1);

  luaL_argcheck(L, dW == 1, 1, "dW must be 1 (this will be fixed soon)");
  luaL_argcheck(L, dH == 1, 1, "dH must be 1 (this will be fixed soon)");

  THCudaTensor *gradWeight = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "gradWeight", "torch.CudaTensor");
  THCudaTensor *gradBias = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "gradBias", "torch.CudaTensor");

  float *gradBias_data = THCudaTensor_data(gradBias);
  float *gradOutput_data = THCudaTensor_data(gradOutput);

  if (input->nDimension == 3)
  {
    /* check dims */
    THArgCheck(nOutputPlane == gradOutput->size[0], 1, "Number of output features is not equal to nOutputPlane");

    /* gradient to bias */
    dim3 blocks(nOutputPlane);
    dim3 threads(32);
    compute_gradBias <<<blocks, threads>>> (gradBias_data, gradOutput_data, scale,
                                            gradOutput->size[0], gradOutput->size[1], gradOutput->size[2]);

    /* gradient to kernels */
    THCudaTensor_conv2DRevger(gradWeight, 1.0, scale, input, gradOutput, dH, dW);
  }
  else
  {
    /* check dims */
    THArgCheck(nOutputPlane == gradOutput->size[1], 1, "Number of output features is not equal to nOutputPlane");

    /* gradient to bias */
    dim3 blocks(nOutputPlane);
    long sl;
    for (sl=0; sl<gradOutput->size[0]; sl+=16) {
      int cst = 16;
      if ((cst+sl) > gradOutput->size[0]) cst = gradOutput->size[0] - sl;
      dim3 threads(16, cst);
      compute_gradBias <<<blocks, threads>>> (gradBias_data, gradOutput_data + sl*gradOutput->stride[0], scale,
                                              gradOutput->size[1], gradOutput->size[2], gradOutput->size[3]);
    }

    /* gradient to kernels */
    THCudaTensor_conv2DRevgerm(gradWeight, 1.0, scale, input, gradOutput, dH, dW);
  }

  return 0;
}

static const struct luaL_Reg cunn_SpatialConvolutionNew__ [] = {
  {"SpatialConvolutionNew_updateOutput", cunn_SpatialConvolutionNew_updateOutput},
  {"SpatialConvolutionNew_updateGradInput", cunn_SpatialConvolutionNew_updateGradInput},
  {"SpatialConvolutionNew_accGradParameters", cunn_SpatialConvolutionNew_accGradParameters},
  {NULL, NULL}
};

static void cunn_SpatialConvolutionNew_init(lua_State *L)
{
  luaT_pushmetatable(L, "torch.CudaTensor");
  luaT_registeratname(L, cunn_SpatialConvolutionNew__, "nn");
  lua_pop(L,1);
}
