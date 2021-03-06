#ifndef assert
#define assert(e)  \
    if (!(e)) { \
        printf("failed assertion `%s'\n", #e); \
        THError("aborting..."); \
    };
#endif

#ifndef MIN
#define MIN(X,Y) ((X) < (Y) ? (X) : (Y))
#endif

#ifndef MAX
#define MAX(X,Y) ((X) < (Y) ? (Y) : (X))
#endif




__global__ void SCinputcopykernelsmall(float* inputptr, float* icopyptr, int stridey, int bs, int ih, 
      int iw, int ip, int padtop, int padleft, int toh, int tiw)
{
      /* blockIdx.z  = s     [ 0, stridey-1 ]
         blockIdx.y  = it1   [ 0, bs-1      ]
         blockIdx.x  = it3   [ 0, (iw/blockDim.y)-1+1      ]
         threadIdx.x = it4x  [ 0, ip-1      ]
         threadIdx.y = it4y  [ 0, 32/ip-1   ]
      // this is the special case where ip < 32 and the input is contiguous (optimized coalescing for input layer)
       */
         
      int fout = (MAX(0,padtop-blockIdx.z)+stridey-1)/stridey;
      int fin = fout * stridey - padtop + blockIdx.z;

      if (fin < ih) 
      {
         inputptr += (blockIdx.y)*ih*iw*ip+fin*iw*ip;
         icopyptr += blockIdx.z*bs*toh*tiw*ip+(blockIdx.y)*toh*tiw*ip+fout*tiw*ip+padleft*ip;
         
         int inputsize2   = ((ih-fin) + stridey - 1) / stridey;

         for (int it2=0; it2<inputsize2; it2++) { 
            if((blockIdx.x*blockDim.y)*ip+threadIdx.x+blockDim.x*threadIdx.y<ip*iw) {
            icopyptr[(blockIdx.x*blockDim.y)*ip+threadIdx.x+blockDim.x*threadIdx.y]=inputptr[(blockIdx.x*blockDim.y)*ip+threadIdx.x+blockDim.x*threadIdx.y];
            }
            inputptr += stridey*iw*ip;
            icopyptr += tiw*ip;
			}
      }
}
      





__global__ void SCinputcopykernel(float* inputptr, float* icopyptr, int stridey, int bs, int ih, 
      int iw, int ip, int padtop, int padleft, int toh, int tiw, int inputstr0, int inputstr1, int inputstr2, int inputstr3)
{
      // blockIdx.z  = s     [ 0, stridey-1 ]
      // blockIdx.y  = it1   [ 0, bs-1      ]
      // blockIdx.x  = it3   [ 0, iw-1      ]
      // threadIdx.x = it4   [ 0, 31        ]
      // icopy is supposed to be contiguous as it is a local temporary matrix
       
         
      int fout = (MAX(0,padtop-blockIdx.z)+stridey-1)/stridey;
      int fin = fout * stridey - padtop + blockIdx.z;

      if (fin < ih) 
      {
         inputptr += (blockIdx.y)*inputstr0+fin*inputstr1+(blockIdx.x)*inputstr2;
         icopyptr += blockIdx.z*bs*toh*tiw*ip+(blockIdx.y)*toh*tiw*ip+fout*tiw*ip+(padleft+blockIdx.x)*ip;
         
         int inputsize2   = ((ih-fin) + stridey - 1) / stridey;

         for (int it2=0; it2<inputsize2; it2++) { 
            for (int it4=threadIdx.x; it4<ip; it4+=blockDim.x) 
            {
               icopyptr[it4]=inputptr[it4];
            }
            inputptr += stridey*inputstr1;
            icopyptr += tiw*ip;
			}
      }
}







__global__ void SCoutputcopykernel(float* outputptr, float* ocopyptr, float* biasptr, int bs, int oh, 
      int ow, int op, int toh, int tow, int outputstr0, int outputstr1, int outputstr2, int outputstr3)
      {
      /* blockIdx.z  = it1   [ 0, bs-1      ]
         blockIdx.y  = it2   [ 0, oh-1      ]
         blockIdx.x  = it3   [ 0, ow-1      ]
         threadIdx.x = it4   [ 0, 31        ]
       */      
         outputptr += (blockIdx.z)*outputstr0+(blockIdx.y)*outputstr1+(blockIdx.x)*outputstr2;
         ocopyptr  += (blockIdx.z)*toh*tow*op+(blockIdx.y)*tow*op+(blockIdx.x)*op;
         for (int it4=threadIdx.x; it4<op; it4+=blockDim.x) {
            outputptr[it4]=ocopyptr[it4] + biasptr[it4];
		   }
      }



__global__ void transpose12(float* in, float* out, int instr0, int instr1, int outstr0, int outstr1)
{
   /*
      blockIdx.x =  [ 0, kH-1 ]
      blockIdx.y =  [ 0, op-1 ]
      threadIdx.x = [ 0, 31   ]
   */
   
   in  +=   blockIdx.x * instr1 + blockIdx.y * instr0;
   out +=   blockIdx.x * outstr0 + blockIdx.y * outstr1;
   
   for (int i=threadIdx.x; i<instr1; i+=blockDim.x)
   {
      out[i]=in[i];
   }
}




static int cunxn_SpatialConvolution_updateOutput(lua_State *L)
{
  THCudaTensor *input = (THCudaTensor *)luaT_checkudata(L, 2, "torch.CudaTensor");
  THCudaTensor *output = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "output", "torch.CudaTensor");
  THCudaTensor *tmpweight = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "weight", "torch.CudaTensor");
  THCudaTensor *bias = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "bias", "torch.CudaTensor");
  THCudaTensor *weight = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "tmpweight", "torch.CudaTensor");


  /* transpose weight dims 1 and 2 so it is in proper format */

  int t_kH = tmpweight->size[1];
  int t_op = tmpweight->size[0];
  int t_kW = tmpweight->size[2];
  int t_ip = tmpweight->size[3];
  THCudaTensor_resize4d(weight, t_kH, t_op, t_kW, t_ip);

  float* w0ptr = THCudaTensor_data(tmpweight);
  float* w1ptr = THCudaTensor_data(weight);
  
  int w0str0   = tmpweight->stride[0];
  int w0str1   = tmpweight->stride[1];
  int w1str0   = weight->stride[0];
  int w1str1   = weight->stride[1];
  
  dim3 transposeblocks(t_kH, t_op);
  dim3 transposethreads(32);
  
  transpose12<<<transposeblocks,transposethreads>>>(w0ptr, w1ptr, w0str0, w0str1, w1str0, w1str1);
  
  /* end of transposition */ 



  int stridex = luaT_getfieldcheckint(L, 1, "dW");
  int stridey = luaT_getfieldcheckint(L, 1, "dH");

  int padleft = luaT_getfieldcheckint(L, 1, "padleft");
  int padright = luaT_getfieldcheckint(L, 1, "padright");
  int padtop = luaT_getfieldcheckint(L, 1, "padtop");
  int padbottom = luaT_getfieldcheckint(L, 1, "padbottom");

  int overlap = luaT_getfieldcheckint(L, 1, "overlap");

  float onef=1;

  int bs = input->size[0];
  int ih = input->size[1];
  int iw = input->size[2];
  int ip = input->size[3];

  int inputstr0 = input->stride[0];
  int inputstr1 = input->stride[1];
  int inputstr2 = input->stride[2];
  int inputstr3 = input->stride[3];
  
  int kh = weight->size[0];
  int op = weight->size[1];
  int kw = weight->size[2];
//  printf("ip: %d, weight : %d\n", ip, weight->size[3]);
  assert(ip==weight->size[3]);
  
  /* compute output size */
  int ow = ( iw + padleft + padright - kw ) / stridex + 1;
  int oh = ( ih + padtop + padbottom - kh ) / stridey + 1;

  /* correct padright and padbottom */
  padright = ow * stridex + kw - stridex - iw - padleft;
  padbottom = oh * stridey + kh - stridey - ih - padtop;
  /* assert(not exact or padright ~= oldpadright, "horizontal size mismatch"); */
  /* assert(not exact or padbottom ~= oldpadbottom, "horizontal size mismatch"); */
  if (padright < 0)  { padright = 0;}
  if (padbottom < 0) { padbottom = 0;}

  /* input size with padding */
  int piw = padleft + iw + padright; 
  int pih = padtop + ih + padbottom;

  /* number of horizontal strides between nonoverlapping runs */
  int nxs = 1;
  if (!overlap) { nxs = (kw + stridex - 1) / stridex ;}

  /* total size of output buffer */
  int tow = (piw + stridex - 1) / stridex;
  int toh = (pih + stridey - 1) / stridey;

  /* total size of input and output buffers */
  int tiw = tow * stridex;
  int tih = toh * stridey;  
  assert(tiw >= piw && piw >= iw);
  assert(tih >= pih && pih >= ih);

  /*icopy =  newSameTensor(input, stridey, bs, toh, tiw, ip) */
  THLongStorage *icopysize = THLongStorage_newWithSize(5);
  icopysize->data[0]=stridey;
  icopysize->data[1]=bs;
  icopysize->data[2]=toh;
  icopysize->data[3]=tiw;
  icopysize->data[4]=ip;
  THCudaTensor* icopy = THCudaTensor_newWithSize(icopysize, NULL);
  THCudaTensor_fill(icopy, 0);

  float* icopyptr=THCudaTensor_data(icopy);
  float* inputptr=THCudaTensor_data(input);

 
  if(ip<32 && THCudaTensor_isContiguous(input)) {
      dim3 icopyblocks(iw/(32/ip)+1, bs, stridey);
      dim3 icopythreads(MIN(32,ip), 32/ip);
      SCinputcopykernelsmall <<<icopyblocks, icopythreads>>> (inputptr, icopyptr, stridey, bs, ih, iw, ip, padtop, padleft, toh, tiw);
  }
  else {
      dim3 icopyblocks(iw, bs, stridey);
      dim3 icopythreads(32);
      SCinputcopykernel <<<icopyblocks, icopythreads>>> (inputptr, icopyptr, stridey, bs, ih, iw, ip, padtop, padleft, toh, tiw, inputstr0, inputstr1, inputstr2, inputstr3);
  }
  

  
  THCudaTensor* kcopy = weight;
  
  

  
  THCudaTensor* ocopy = THCudaTensor_newWithSize4d(bs, toh, tow, op);
  THCudaTensor_fill(ocopy, 0);

  cublasHandle_t handle;
  cublasStatus_t err = cublasCreate(&handle);
  if (err != CUBLAS_STATUS_SUCCESS) { printf("error in creating handle"); }

   /* call GEMM */
	int hcall;
   for (hcall=0; hcall<nxs; hcall++) {
	   int vcall;
      for (vcall=0; vcall<kh; vcall++) {
         int sq = vcall / stridey;
         int sr = vcall - sq * stridey;
         /* local icopy =  newSameTensor(input, stridey, bs, toh, tiw, ip) */
         /* float* iptr = torch.data(icopy[{sr+1,{},sq+1,hcall*stridex+1,{}}]) */
		   float* iptr = THCudaTensor_data(icopy);
		   iptr       += (sr)*icopy->stride[0] + (sq)*icopy->stride[2] +  (hcall*stridex)*icopy->stride[3];

         /* local kptr  = torch.data(kcopy:select(1,vcall+1)) */
		   float* kptr = THCudaTensor_data(kcopy);
		   kptr	 	+= vcall * kcopy->stride[0];

         /* local optr = torch.data(ocopy:select(3,hcall+1)) */
		   float* optr = THCudaTensor_data(ocopy);
         optr		+= hcall * ocopy->stride[2];


         int nrun = (bs-1)*toh*tow + oh*tow;
         int ngem = (nrun - hcall) / nxs;

         err = cublasSgemm(handle,
                           CUBLAS_OP_T, CUBLAS_OP_N,
                           op, ngem, kw*ip,
                           &onef,
                           kptr, kw*ip,
                           iptr, nxs*stridex*ip,
                           &onef,
                           optr, nxs*op );     
              
              
              
         if (err != CUBLAS_STATUS_SUCCESS) { printf("error in sgemm"); }
      }
   }


  err = cublasDestroy(handle);
  if (err != CUBLAS_STATUS_SUCCESS) { printf("error in destroying handle"); }

  // will output a contiguous matrix, except if the tensor is of proper size, in which case output will be recycled
  if(output->nDimension==4)
  {
     if(output->size[0] != bs || output->size[1] != oh || output->size[2] != ow || output->size[3] != op)
     {
         THCudaTensor_resize4d(output, bs, oh, ow, op);
     }
  }
  else //if the tensor doesn't exist...
  {
         THCudaTensor_resize4d(output, bs, oh, ow, op);
  }
   
  float* ocopyptr=THCudaTensor_data(ocopy);
  float* outputptr=THCudaTensor_data(output);
  float* biasptr=THCudaTensor_data(bias);

  dim3 ocopyblocks(ow, oh, bs);
  dim3 ocopythreads(32);

  int outputstr0 = output->stride[0];
  int outputstr1 = output->stride[1];
  int outputstr2 = output->stride[2];
  int outputstr3 = output->stride[3];
  
  SCoutputcopykernel <<<ocopyblocks, ocopythreads>>> (outputptr, ocopyptr, biasptr, bs, oh, ow, op, toh, tow, outputstr0, outputstr1, outputstr2, outputstr3);


  // check for errors
  cudaError_t lasterror = cudaGetLastError();
  if (lasterror != cudaSuccess) {
    printf("error in SpatialConvolution.updateOutput: %s\n", cudaGetErrorString(lasterror));
    THError("aborting");
  }
 
  // final cut:
  //THCudaTensor_free(input); 
  THCudaTensor_free(icopy);
  THCudaTensor_free(ocopy);
  //THCudaTensor_select(output, NULL, dimension, 0);

  return 1;
}







__global__ void SCkernelCopyReverse(float* weightptr, float* revkptr, int stridey, int stridex, int kouth, 
      int koutw, int kouto, int kouti, int sh, int so, int sw, int si, int kh, int kw, int ko, int ki)
{
   /*
         blockIdx.z  =    [ 0, ceil(ki/32)] -> usually this should be good
            inputplane = blockIdx.z * blockDim.x+threadIdx.x
         blockIdx.y  =    [ 0, stry-1    ]
         blockIdx.x  =    [ 0, strx-1    ]
         threadIdx.x =    [ 0, 31        ] -> weight input dim
         threadIdx.y =    [ 0, 31        ] -> weight output dim
            outputplane= iterator * blockDim.y + threadIdx.y
   */
   const int stry=blockIdx.y;
   const int strx=blockIdx.x;

   // put revkptr on proper stry,strx submatrix
   revkptr  +=    (blockIdx.y*stridex + blockIdx.x)*kouth*kouto*koutw*kouti;

   
   __shared__ float weightvalues[32][33];
   // for given x,y : weightvalues[inputplane][outputplane]
   
   
   int ith, itw, xcoord, ycoord, ito;
   for(ith=0; ith<kouth; ith++) {
      ycoord=kh-(ith*stridey+stry+1);
      if (ycoord<kh && ycoord>-1) {
         for(itw=0; itw<koutw; itw++) {
	   	   xcoord=kw-(itw*stridex+strx+1);
				if (xcoord<kw && xcoord>-1) {         

/*              int kh = weight->size[0];
              int op = weight->size[1];
              int kw = weight->size[2];
              assert(ip==weight->size[3]);            */
         
         for (ito=0; ito<(ko+blockDim.y-1)/blockDim.y; ito++) {

         /* iterate over tiles of size 32*32 */

         /* Step 1 : for a given (x,y)
            read weight(y, [32o], x, [32i]) and store the stuff in shmem */

                  const int curoplane=ito*blockDim.y+threadIdx.y;
                  const int curiplane=blockIdx.z * blockDim.x+threadIdx.x;
                  
                  if(curiplane<ki && curoplane<ko) {
                     weightvalues[threadIdx.x][threadIdx.y]=weightptr[ycoord*sh+xcoord*sw+(curoplane)*so+(curiplane)*si];
                  }
                  
                  __syncthreads();

         /* Step 2 : write revk(ith, [32i], itw, [32o]) in submatrix */
                  
                  const int reviplane=blockIdx.z * blockDim.y + threadIdx.y;
                  const int revoplane=ito*blockDim.x+threadIdx.x;
                  
                  if( reviplane < ki && revoplane < ko) {
                     revkptr[ith*kouto*koutw*kouti + itw*kouti + reviplane*koutw*kouti + revoplane] = weightvalues[threadIdx.y][threadIdx.x];
                  }

                  __syncthreads();

         }
         
         
   
         
         }
         }
      }
   }
   


   
}










__global__ void SCcopyGradOut(float* goptr, float* gocpyptr, int goh, int gow, int pgoh, int pgow, int revkh, int revkw, int op, int gradOutstr0, int gradOutstr1, int gradOutstr2, int gradOutstr3   )
{
   /* blockIdx.z  = [ 0, bs-1  ] (it1)
      blockIdx.y  = [ 0, goh-1 ] (it2)
      blockIdx.x  = [ 0, gow-1 ] (it3)
      threadIdx.x = [ 0, 31    ] (it4)
   */

   gocpyptr += ((blockIdx.z*pgoh+(revkh -1 + blockIdx.y))*pgow+(revkw-1+blockIdx.x))*op;
   goptr += ((blockIdx.z*goh+blockIdx.y)*gow+blockIdx.x)*gradOutstr2;

   int i;
   for(i=threadIdx.x; i<op; i+=blockDim.x)
   {
      gocpyptr[i]=goptr[i];
   }

}







__global__ void SCcopyGradinResult(float* gradinptr, float* resptr, int throwawayx, int throwawayy, int stridey, int rs0, int rs1, int rs2, int gs0, int gs1, int gs2, int gs3, int ip, int gih, int padtop, int padleft, int ih, int iw)
{
   /*
      blockIdx.z  = [ 0, bs-1 ] (it1)
      blockIdx.y  = [ 0 ] 
      blockIdx.x  = [ 0, iw ] (it3)
      threadIdx.x = [ 0, 31   ] (it4)
   */

   int starty, sizey;
   
   resptr   += blockIdx.z*rs0 + blockIdx.x*rs2;
   gradinptr+= blockIdx.z*gs1 + (padleft + throwawayx + blockIdx.x)*gs3;
   
   float* tresptr ;
   float* tgradinptr;
   
   for(int stry=stridey; stry>0; stry--) {
   	int throwaway = stridey-stry < throwawayy;
	   if(throwaway) {
	   	starty = (stridey-stry+1) - throwawayy + stridey -1 ;
   		sizey  = gih-1;
   	}
	   else 	{ 
		   starty = (stridey-stry+1) - throwawayy -1 ;
		   sizey  = gih;
	   }
	   
	   for(int it2=0; it2<sizey; it2++) {
	      if((starty + it2*stridey - padtop)>-1 && (starty + it2*stridey - padtop)<ih)
	      {
            tresptr	   = resptr    + (starty + it2*stridey - padtop)*rs1;
            tgradinptr	= gradinptr + (stry-1)*gs0;
            if(throwaway)  { tgradinptr += (it2+1)*gs2 ; }
            else           { tgradinptr += it2*gs2 ; }
      
            for(int it4=threadIdx.x; it4<ip; it4+=blockDim.x)
            {
               tresptr[it4]= tgradinptr[it4];
            }
         }
      }
   }
   
}








static int cunxn_SpatialConvolution_updateGradInput(lua_State *L)
{
  THCudaTensor *input = (THCudaTensor *)luaT_checkudata(L, 2, "torch.CudaTensor");
  THCudaTensor *gradOutput = (THCudaTensor *)luaT_checkudata(L, 3, "torch.CudaTensor");
  THCudaTensor *weight = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "tmpweight", "torch.CudaTensor");
  THCudaTensor *tmpweight = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "weight", "torch.CudaTensor");
//  int dimension  = luaT_getfieldcheckint(L, 1, "dimension")-1;
  THCudaTensor *result  = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "gradInput", "torch.CudaTensor");
  THCudaTensor *revk;




  /* transpose weight dims 1 and 2 so it is in proper format */

  int t_kH = tmpweight->size[1];
  int t_op = tmpweight->size[0];
  int t_kW = tmpweight->size[2];
  int t_ip = tmpweight->size[3];
  THCudaTensor_resize4d(weight, t_kH, t_op, t_kW, t_ip);

  float* w0ptr = THCudaTensor_data(tmpweight);
  float* w1ptr = THCudaTensor_data(weight);
  
  int w0str0   = tmpweight->stride[0];
  int w0str1   = tmpweight->stride[1];
  int w1str0   = weight->stride[0];
  int w1str1   = weight->stride[1];
  
  dim3 transposeblocks(t_kH, t_op);
  dim3 transposethreads(32);
  
  transpose12<<<transposeblocks,transposethreads>>>(w0ptr, w1ptr, w0str0, w0str1, w1str0, w1str1);
  
  /* end of transposition */ 





  int stridex = luaT_getfieldcheckint(L, 1, "dW");
  int stridey = luaT_getfieldcheckint(L, 1, "dH");

  int padleft = luaT_getfieldcheckint(L, 1, "padleft");
  int padright = luaT_getfieldcheckint(L, 1, "padright");
  int padtop = luaT_getfieldcheckint(L, 1, "padtop");
  int padbottom = luaT_getfieldcheckint(L, 1, "padbottom");

  int overlap = luaT_getfieldcheckint(L, 1, "overlap");
  //assert(overlap==1);

  int nOutputPlane = luaT_getfieldcheckint(L, 1, "nOutputPlane");

  int bs = input->size[0];
  int ih = input->size[1];
  int iw = input->size[2];
  int ip = input->size[3];

  int kh = weight->size[0];
  int op = weight->size[1];
  int kw = weight->size[2];
  assert(ip==weight->size[3]);


   assert(gradOutput->nDimension == 4);
   assert(bs == gradOutput->size[0]);
   /* check that output h,w sizes match gradOutput sizes      */
   int goh = gradOutput->size[1];
   int gow = gradOutput->size[2];
   assert(goh == (ih + padtop + padbottom - kh) / stridey + 1) ;
   assert(gow == (iw + padleft + padright - kw) / stridex + 1) ;
   assert(op == gradOutput->size[3]);



   /*copyKernelReverse*/


   int ko = weight->size[1];
   int ki = weight->size[3];
   
   int sh = weight->stride[0];
   int so = weight->stride[1];
   int sw = weight->stride[2];
   int si = weight->stride[3];
   
   
   
   int kouth=(kh+stridey-1)/stridey;
   int kouto=ki;
   int koutw=(kw+stridex-1)/stridex;
   int kouti=ko;

   /* clean this after... */
   int revkh=kouth;
   int revkw=koutw;

   THLongStorage *revksize = THLongStorage_newWithSize(6);
   revksize->data[0]=stridey;
   revksize->data[1]=stridex;
   revksize->data[2]=kouth;
   revksize->data[3]=kouto;
   revksize->data[4]=koutw;
   revksize->data[5]=kouti;

   revk = THCudaTensor_newWithSize(revksize, NULL);
   THCudaTensor_fill(revk, 0);
   
   float* weightptr=THCudaTensor_data(weight);
   float* revkptr=THCudaTensor_data(revk);
   
   dim3 kcrblocks(stridex, stridey, (ki+31)/32);
   dim3 kcrthreads(32,32);
   
   
   SCkernelCopyReverse <<<kcrblocks, kcrthreads>>>(weightptr, revkptr, stridey, stridex, kouth, 
      koutw, kouto, kouti, sh, so, sw, si, kh, kw, ko, ki);
   /*
         blockIdx.z  =    [ 0, ceil(ki/32)] -> parallelizing over inputplanes dimension : 
            usually there will be lots of them except in data layer where there is no backprop
            inputplane = blockIdx.z * blockDim.x+threadIdx.x
         blockIdx.y  =    [ 0, stry-1    ]
         blockIdx.x  =    [ 0, strx-1    ]
         threadIdx.x =    [ 0, 31        ] -> weight input dim
         threadIdx.y =    [ 0, 31        ] -> weight output dim
            outputplane= iterator * blockDim.y + threadIdx.y
   */
   
   
   /* end of copyKernelReverse */
   
   
   
   /* create gradinput tensor :*/
   int giw = ( gow + revkw -1 ) * stridex;
   int gih = ( goh + revkh -1 ) ;

   THLongStorage *gradinsize = THLongStorage_newWithSize(5);
   gradinsize->data[0]=stridey;
   gradinsize->data[1]=bs;
   gradinsize->data[2]=gih;
   gradinsize->data[3]=giw;
   gradinsize->data[4]=ip;

   THCudaTensor * gradin = THCudaTensor_newWithSize(gradinsize, NULL);
   THCudaTensor_fill(gradin, 0);
   
   
   /* pad gradoutput tensor :*/
   int pgow = ( gow + revkw -1 );
   int pgoh = ( goh + revkh -1 );

   
   /* here we take bs+1 to have some zero-padding at the end of the matrix */
   /* it only costs some memory. GEMM does not use it. */

   THLongStorage *gradoutsize = THLongStorage_newWithSize(4);
   gradoutsize->data[0]=bs+1;
   gradoutsize->data[1]=pgoh;
   gradoutsize->data[2]=pgow;
   gradoutsize->data[3]=op;

   THCudaTensor * gradOutCopy = THCudaTensor_newWithSize(gradoutsize, NULL);
   THCudaTensor_fill(gradOutCopy, 0);

   float* goptr=THCudaTensor_data(gradOutput);
   float* gocpyptr=THCudaTensor_data(gradOutCopy);

   /* Convert this to a CUDA kernel 
   
   // Lua :
   gradOutCopy = newSameTensor(gradOutput, bs+1, pgoh, pgow, op) 
   tgocopy=narrowTensorAndZero(gradOutCopy, 1, 1, bs)
   tgocopy=narrowTensorAndZero(tgocopy, 2, revkh, goh)
   tgocopy=narrowTensorAndZero(tgocopy, 3, revkw, gow)
   tgocopy:copy(gradOutput)


   // C :
   real* goptr=THTensor_(data)(gradOutput);
   real* gocpyptr=THTensor_(data)(gradOutCopy);

   int itgocpy0=0;
   int itgo=0;

   int it1, it2, it3, it4;
   for (it1=0; it1<bs; it1++) {
		int itgocpy1	=	itgocpy0+(it1)*pgoh*pgow*op;
	    for (it2=0; it2<goh; it2++) { 
			int itgocpy2=itgocpy1+(revkh-1+it2)*pgow*op;
			for (it3=0; it3<gow; it3++ ) {
				int itgocpy3=itgocpy2+(revkw-1+it3)*op;
				for (it4=0; it4<op; it4++) {
					gocpyptr[itgocpy3]=goptr[itgo];
					itgocpy3++;
					itgo++;
				}
			}
		}
	} 

   
   */
   
   dim3 cgoblocks(gow, goh, bs);
   dim3 cgothreads(32);
   
  int gradOutstr0 = gradOutput->stride[0];
  int gradOutstr1 = gradOutput->stride[1];
  int gradOutstr2 = gradOutput->stride[2];
  int gradOutstr3 = gradOutput->stride[3];
  
   
   
   SCcopyGradOut <<< cgoblocks, cgothreads >>>(goptr, gocpyptr, goh, gow, pgoh, pgow, revkh, revkw, op, gradOutstr0, gradOutstr1, gradOutstr2, gradOutstr3);

   /* blockIdx.z  = [ 0, bs-1  ] (it1)
      blockIdx.y  = [ 0, goh-1 ] (it2)
      blockIdx.x  = [ 0, gow-1 ] (it3)
      threadIdx.x = [ 0, 31    ] (it4)
   */
   
   /* end of copyGradOut */
   
   float onef=1;
   
  cublasHandle_t handle;
  cublasStatus_t err = cublasCreate(&handle);
  if (err != CUBLAS_STATUS_SUCCESS) { printf("error in creating handle"); }
   
   /* GEMM calls : */
	int nxs=1;
	if(!overlap) {
	   nxs=revkw; 
	   //printf("no overlap");
	}
	for (int hcall=0; hcall<nxs; hcall++) {
	   for (int stry=0; stry<stridey; stry++) {
		   for (int strx=0; strx<stridex; strx++) {
			   for (int vcall=0; vcall<revkh; vcall++) {
				   float* gradoutptr  = THCudaTensor_data(gradOutCopy);
				   gradoutptr		   += (revkh-vcall-1)*gradOutCopy->stride[1] + hcall*gradOutCopy->stride[2];
               int ldgradout      = op*nxs;
                     
				   float* krevptr	    = THCudaTensor_data(revk);
				   krevptr 		      += (stry)*revk->stride[0] + (strx)*revk->stride[1] + (revkh-vcall-1)*revk->stride[2];
               int szkrev         = op*revkw;
               int ldkrev     	 = op*revkw;
                  
				   float* gradinptr	 = THCudaTensor_data(gradin);
				   gradinptr		+= (stry)*gradin->stride[0] + (stridex-(strx)-1+hcall*stridex)*gradin->stride[3];
               int ldgradin   	 = ip * stridex * nxs;
                  
               int nspots         = giw/stridex*gih*bs;
               int ngem           = (nspots-hcall+nxs-1)/nxs;
                  
               err = cublasSgemm(handle,
                           CUBLAS_OP_T, CUBLAS_OP_N,
                           ip, ngem, szkrev,
                           &onef,
                           krevptr, ldkrev,
                           gradoutptr, ldgradout,
                           &onef,
                           gradinptr, ldgradin );

               if (err != CUBLAS_STATUS_SUCCESS) { printf("error in sgemm"); }
               //else {printf("called sgemm..."); }
			   }
		   }
	   }
   }

  err = cublasDestroy(handle);
  if (err != CUBLAS_STATUS_SUCCESS) { printf("error in destroying handle"); }
   
   
   
   
   
   
   
   
   
   
   
   
     /* correct padright and padbottom */
  //int oldpadright = padright;
  //int oldpadbottom = padbottom;
  padright = gow * stridex + kw - stridex - iw - padleft;
  padbottom = goh * stridey + kh - stridey - ih - padtop;
  /* assert(not exact or padright ~= oldpadright, "horizontal size mismatch"); */
  /* assert(not exact or padbottom ~= oldpadbottom, "horizontal size mismatch"); */
  if (padright < 0)  { padright = 0;}
  if (padbottom < 0) { padbottom = 0;}

  /* input size with padding */
  //int piw = padleft + iw + padright; 
  //int pih = padtop + ih + padbottom;



    
   int throwawayx=stridex - kw%stridex;
   int throwawayy=stridey - kh%stridey;
   if (stridex==1 || stridex==throwawayx) { throwawayx=0 ; } 
   if (stridey==1 || stridey==throwawayy) { throwawayy=0 ; }

   /* clean this after */ 
   int resw=iw;
   int resh=ih;

  // will output a contiguous matrix, except if the tensor is of proper size, in which case output will be recycled
  // gradinput is zeroed by forward calls
  if(result->nDimension==4)
  {
     if(result->size[0] != bs || result->size[1] != resh || result->size[2] != resw || result->size[3] != ip)
     {
         THCudaTensor_resize4d(result, bs, resh, resw, ip);
         THCudaTensor_fill(result, 0);
     }
  }
  else //if the tensor doesn't exist...
  {
         THCudaTensor_resize4d(result, bs, resh, resw, ip);
         THCudaTensor_fill(result, 0);
  }
   



   float* gradinptr = THCudaTensor_data(gradin);
   float* resptr = THCudaTensor_data(result);

   dim3 cgirblocks(iw, 1, bs);
   dim3 cgirthreads(32);

   int rs0 = result->stride[0];
   int rs1 = result->stride[1];
   int rs2 = result->stride[2];
   int gs0 = gradin->stride[0]; 
   int gs1 = gradin->stride[1];
   int gs2 = gradin->stride[2];
   int gs3 = gradin->stride[3];
 

   SCcopyGradinResult <<<cgirblocks,cgirthreads>>> (gradinptr, resptr, throwawayx, throwawayy, stridey, rs0, rs1, rs2, gs0, gs1, gs2, gs3, ip, gih, padtop, padleft, ih, iw);
   /*
      blockIdx.z  = [ 0, bs-1 ] (it1)
      blockIdx.y  = [ 0 ] 
      blockIdx.x  = [ 0, iw ] (it3)
      threadIdx.x = [ 0, 31   ] (it4)
   */

   
   
   THCudaTensor_free(gradin);
   THCudaTensor_free(revk);
   THCudaTensor_free(gradOutCopy);
   
   
   
   
   
   //THCudaTensor_resizeAs(gradInput, result);
   //THCudaTensor_copy(gradInput, result);
   
   
      

  // check for errors
  cudaError_t err2 = cudaGetLastError();
  if (err2 != cudaSuccess) {
    printf("error in SpatialConvolution.updateOutput: %s\n", cudaGetErrorString(err2));
    THError("aborting");
  }

  return 1;
}





__global__ void SCcopyGradOutInBuffer(float* goptr, float* gocpyptr, int oh, int ow, int toh, int tow, int op, int gradOutstr0, int gradOutstr1, int gradOutstr2, int gradOutstr3)
{
   /* blockIdx.z  = [ 0, bs-1  ] (it1)
      blockIdx.y  = [ 0, oh-1  ] (it2)
      blockIdx.x  = [ 0, ow-1  ] (it3)
      threadIdx.x = [ 0, 31    ] (it4)
   */

   gocpyptr += blockIdx.z*toh*tow*op + blockIdx.y*tow*op + blockIdx.x*op;
   goptr += ((blockIdx.z*oh+blockIdx.y)*ow+blockIdx.x)*gradOutstr2;

   int i;
   for(i=threadIdx.x; i<op; i+=blockDim.x)
   {
      gocpyptr[i]=goptr[i];
   }

}




__global__ void SCcomputeGradBias(float* goptr, float* gradbiasptr, int bs, int oh, int ow, int op, float scale, int gradOutstr0, int gradOutstr1, int gradOutstr2, int gradOutstr3)
{
   /* blockIdx.x  = [ 0, ceil(op/32) ]
      blockIdx.y  = [ 0, bs-1        ]
      threadIdx.x = [ 0, 31          ]   
   */

   goptr += blockIdx.y*gradOutstr0;
   const int idx = blockIdx.x * blockDim.x + threadIdx.x;
   
   float b=0;
   
   if (idx<op) {
      for(int i=0; i<oh*ow; i++) {
         b += goptr[i*gradOutstr2 + idx];
      }
   atomicAdd(&gradbiasptr[idx], b*scale);
   }
   
}






static int cunxn_SpatialConvolution_accGradParameters(lua_State *L)
{



  THCudaTensor *input = (THCudaTensor *)luaT_checkudata(L, 2, "torch.CudaTensor");
  THCudaTensor *gradOutput = (THCudaTensor *)luaT_checkudata(L, 3, "torch.CudaTensor");
  THCudaTensor *gradWeight = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "tmpgradweight", "torch.CudaTensor");
  THCudaTensor *tmpgradweight = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "gradWeight", "torch.CudaTensor");
  THCudaTensor *gradBias = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "gradBias", "torch.CudaTensor");



  /* transpose weight dims 1 and 2 so it is in proper format */

  int t_kH = tmpgradweight->size[1];
  int t_op = tmpgradweight->size[0];
  int t_kW = tmpgradweight->size[2];
  int t_ip = tmpgradweight->size[3];
  THCudaTensor_resize4d(gradWeight, t_kH, t_op, t_kW, t_ip);

  float* w0ptr = THCudaTensor_data(tmpgradweight);
  float* w1ptr = THCudaTensor_data(gradWeight);
  
  int w0str0   = tmpgradweight->stride[0];
  int w0str1   = tmpgradweight->stride[1];
  int w1str0   = gradWeight->stride[0];
  int w1str1   = gradWeight->stride[1];
  
  dim3 transposeblocks(t_kH, t_op);
  dim3 transposethreads(32);
  
  transpose12<<<transposeblocks,transposethreads>>>(w0ptr, w1ptr, w0str0, w0str1, w1str0, w1str1);
  
  /* end of transposition */ 




  float scale = luaL_optnumber(L, 4, 1);

  int stridex = luaT_getfieldcheckint(L, 1, "dW");
  int stridey = luaT_getfieldcheckint(L, 1, "dH");

  int padleft = luaT_getfieldcheckint(L, 1, "padleft");
  int padright = luaT_getfieldcheckint(L, 1, "padright");
  int padtop = luaT_getfieldcheckint(L, 1, "padtop");
  int padbottom = luaT_getfieldcheckint(L, 1, "padbottom");

  int overlap = luaT_getfieldcheckint(L, 1, "overlap");


  float onef=1;


  int bs = input->size[0];
  int ih = input->size[1];
  int iw = input->size[2];
  int ip = input->size[3];

  int inputstr0 = input->stride[0];
  int inputstr1 = input->stride[1];
  int inputstr2 = input->stride[2];
  int inputstr3 = input->stride[3];
  
  int kh = gradWeight->size[0];
  int op = gradWeight->size[1];
  int kw = gradWeight->size[2];
  assert(ip==gradWeight->size[3]);
  
  /* compute output size */
  int ow = ( iw + padleft + padright - kw ) / stridex + 1;
  int oh = ( ih + padtop + padbottom - kh ) / stridey + 1;

  /* correct padright and padbottom */
//  int oldpadright = padright;
//  int oldpadbottom = padbottom;
  padright = ow * stridex + kw - stridex - iw - padleft;
  padbottom = oh * stridey + kh - stridey - ih - padtop;
  /* assert(not exact or padright ~= oldpadright, "horizontal size mismatch"); */
  /* assert(not exact or padbottom ~= oldpadbottom, "horizontal size mismatch"); */
  if (padright < 0)  { padright = 0;}
  if (padbottom < 0) { padbottom = 0;}

  /* input size with padding */
  int piw = padleft + iw + padright; 
  int pih = padtop + ih + padbottom;

  /* number of horizontal strides between nonoverlapping runs */
  int nxs = 1;
  if (!overlap) { nxs = (kw + stridex - 1) / stridex ;}

  /* total size of output buffer */
  int tow = (piw + stridex - 1) / stridex;
  int toh = (pih + stridey - 1) / stridey;

  /* total size of input and output buffers */
  int tiw = tow * stridex;
  int tih = toh * stridey;  
  assert(tiw >= piw && piw >= iw);
  assert(tih >= pih && pih >= ih);

  /*icopy =  newSameTensor(input, stridey, bs, toh, tiw, ip) */
  THLongStorage *icopysize = THLongStorage_newWithSize(5);
  icopysize->data[0]=stridey;
  icopysize->data[1]=bs;
  icopysize->data[2]=toh;
  icopysize->data[3]=tiw;
  icopysize->data[4]=ip;
  THCudaTensor* icopy = THCudaTensor_newWithSize(icopysize, NULL);
  THCudaTensor_fill(icopy, 0);


  float* icopyptr=THCudaTensor_data(icopy);
  float* inputptr=THCudaTensor_data(input);

 
  if(ip<32 && THCudaTensor_isContiguous(input)) {
      dim3 icopyblocks(iw/(32/ip)+1, bs, stridey);
      dim3 icopythreads(MIN(32,ip), 32/ip);
      SCinputcopykernelsmall <<<icopyblocks, icopythreads>>> (inputptr, icopyptr, stridey, bs, ih, iw, ip, padtop, padleft, toh, tiw);
  }
  else {
      dim3 icopyblocks(iw, bs, stridey);
      dim3 icopythreads(32);
      SCinputcopykernel <<<icopyblocks, icopythreads>>> (inputptr, icopyptr, stridey, bs, ih, iw, ip, padtop, padleft, toh, tiw, inputstr0, inputstr1, inputstr2, inputstr3);
  }
  

  THCudaTensor* kcopy = gradWeight;
  THCudaTensor* ocopy = THCudaTensor_newWithSize4d(bs, toh, tow, op);
  THCudaTensor_fill(ocopy, 0);
  
  float* gradoutptr=THCudaTensor_data(gradOutput);
  float* ocpyptr=THCudaTensor_data(ocopy);
  
  dim3 goibblocks(ow, oh, bs);
  dim3 goibthreads(32);

  int gradOutstr0 = gradOutput->stride[0];
  int gradOutstr1 = gradOutput->stride[1];
  int gradOutstr2 = gradOutput->stride[2];
  int gradOutstr3 = gradOutput->stride[3];
  
  
   SCcopyGradOutInBuffer <<<goibblocks,goibthreads>>>(gradoutptr, ocpyptr, oh, ow, toh, tow, op, gradOutstr0, gradOutstr1, gradOutstr2, gradOutstr3);

   /* blockIdx.z  = [ 0, bs-1  ] (it1)
      blockIdx.y  = [ 0, oh-1  ] (it2)
      blockIdx.x  = [ 0, ow-1  ] (it3)
      threadIdx.x = [ 0, 31    ] (it4)
   */


  float* gradbiasptr=THCudaTensor_data(gradBias);
  
  dim3 gbblocks((op+31)/32, bs);
  dim3 gbthreads(32);
  SCcomputeGradBias <<< gbblocks, gbthreads >>> (gradoutptr, gradbiasptr, bs, oh, ow, op, scale, gradOutstr0, gradOutstr1, gradOutstr2, gradOutstr3);
  
   /* blockIdx.x  = [ 0, ceil(op/32) ]
      threadIdx.x = [ 0, 31          ]   
   */


  cublasHandle_t handle;
  cublasStatus_t err = cublasCreate(&handle);
  if (err != CUBLAS_STATUS_SUCCESS) { printf("error in creating handle"); }

   /* call GEMM */
	int hcall;
   for (hcall=0; hcall<nxs; hcall++) {
	   int vcall;
      for (vcall=0; vcall<kh; vcall++) {
         int sq = vcall / stridey;
         int sr = vcall - sq * stridey;
         /* local icopy =  newSameTensor(input, stridey, bs, toh, tiw, ip) */
         /* float* iptr = torch.data(icopy[{sr+1,{},sq+1,hcall*stridex+1,{}}]) */
		   float* iptr = THCudaTensor_data(icopy);
		   iptr       += (sr)*icopy->stride[0] + (sq)*icopy->stride[2] +  (hcall*stridex)*icopy->stride[3];

         /* local kptr  = torch.data(kcopy:select(1,vcall+1)) */
		   float* kptr = THCudaTensor_data(kcopy);
		   kptr	 	+= vcall * kcopy->stride[0];

         /* local optr = torch.data(ocopy:select(3,hcall+1)) */
		   float* optr = THCudaTensor_data(ocopy);
         optr		+= hcall * ocopy->stride[2];


         int nrun = (bs-1)*toh*tow + oh*tow;
         int ngem = (nrun - hcall) / nxs;

         //printf("calling sgemm...");

         /*THBlas_(gemm)('T','N', op, ngem, kw*ip, 
              1, kptr, kw*ip, iptr, nxs*stridex*ip,
              1, optr, nxs*op ); */
         err = cublasSgemm(handle,
                           CUBLAS_OP_N, CUBLAS_OP_T,
                           kw*ip,op, ngem, 
                           &scale,
                           iptr, nxs*stridex*ip, 
                           optr, nxs*op, 
                           &onef,
                           kptr, kw*ip );     
              
              
              
         if (err != CUBLAS_STATUS_SUCCESS) { printf("error in sgemm"); }
         //else {printf("called sgemm..."); }
      }
   }


  err = cublasDestroy(handle);
  if (err != CUBLAS_STATUS_SUCCESS) { printf("error in destroying handle"); }





  /* transpose weight dims 1 and 2 so it is in proper format */

/*  int t_kH = tmpgradweight->size[1];
  int t_op = tmpgradweight->size[0];
  int t_kW = tmpgradweight->size[2];
  int t_ip = tmpgradweight->size[3];
  THCudaTensor_resize4d(gradWeight, t_kH, t_op, t_kW, t_ip);

  float* w0ptr = THCudaTensor_data(tmpgradweight);
  float* w1ptr = THCudaTensor_data(gradWeight);
  
  int w0str0   = tmpgradweight->stride[0];
  int w0str1   = tmpgradweight->stride[1];
  int w1str0   = gradWeight->stride[0];
  int w1str1   = gradWeight->stride[1];*/
  
  dim3 transposeblocksrev(t_op, t_kH);
  dim3 transposethreadsrev(32);
  
  transpose12<<<transposeblocksrev,transposethreadsrev>>>(w1ptr, w0ptr, w1str0, w1str1, w0str0, w0str1);
  
  /* end of transposition */ 







  // check for errors
  cudaError_t lasterror = cudaGetLastError();
  if (lasterror != cudaSuccess) {
    printf("error in SpatialConvolution.updateOutput: %s\n", cudaGetErrorString(lasterror));
    THError("aborting");
  }
 
  // final cut:
  //THCudaTensor_free(input); 
  THCudaTensor_free(icopy);
  THCudaTensor_free(ocopy);
  //THCudaTensor_select(output, NULL, dimension, 0);

  return 1;

}



__global__ void SCclipWeightsKernel(float* wdataptr, float normbound, int kh, int op, int kw, int ip, int str0, int str1)
{
   /* blockIdx.x  = [ 0, op    ] ()
      threadIdx.x = [ 0, 31    ] ()
   */

   wdataptr += blockIdx.x*str1;

   volatile __shared__ float sqrsums[32];
   int ith, it, i;
   float sqrsum=0;
   float current;
   int numelperline=kw*ip;
   for (ith=0; ith<kh; ith++)
   {
      for(i=threadIdx.x; i<numelperline; i+=blockDim.x)
      {
         current=wdataptr[ith*str0+i];
         sqrsum+=current*current;
      }
   }

   sqrsums[threadIdx.x]=sqrsum;
   
   // NVCC : Y U NO __SHFL ?
   if (threadIdx.x < 16)
   {
      sqrsums[threadIdx.x] += sqrsums[threadIdx.x + 16];
      sqrsums[threadIdx.x] += sqrsums[threadIdx.x + 8];
      sqrsums[threadIdx.x] += sqrsums[threadIdx.x + 4];
      sqrsums[threadIdx.x] += sqrsums[threadIdx.x + 2];
      sqrsums[threadIdx.x] += sqrsums[threadIdx.x + 1];
      sqrsums[threadIdx.x + 1] = sqrsums[threadIdx.x];
      sqrsums[threadIdx.x + 2] = sqrsums[threadIdx.x];
      sqrsums[threadIdx.x + 4] = sqrsums[threadIdx.x];
      sqrsums[threadIdx.x + 8] = sqrsums[threadIdx.x];
      sqrsums[threadIdx.x + 16] = sqrsums[threadIdx.x];
   }

   sqrsum=sqrsums[threadIdx.x];   


   // replace with this when __shfl works :
   /*if (threadIdx.x < 16)
   {
      sqrsums[threadIdx.x] += sqrsums[threadIdx.x + 16];
      sqrsums[threadIdx.x] += sqrsums[threadIdx.x + 8];
      sqrsums[threadIdx.x] += sqrsums[threadIdx.x + 4];
      sqrsums[threadIdx.x] += sqrsums[threadIdx.x + 2];
   }
   if (threadIdx.x == 0)
   {
      sqrsum = sqrsums[0]+sqrsums[1];
   }
   
   sqrsum = __shfl(sqrsum, 0);*/
   
   if(sqrsum>normbound*normbound)
   {
      float scale = normbound/sqrt(sqrsum); 
      for (ith=0; ith<kh; ith++)
      {
         for(i=threadIdx.x; i<numelperline; i+=blockDim.x)
         {
            wdataptr[ith*str0+i] *= scale;
            //wdataptr[ith*str0+i] =0; // for testing...
         }
      }
   }
}





static int cunxn_SpatialConvolution_clipWeights(lua_State *L)
{
  THCudaTensor *weight = (THCudaTensor *)luaT_getfieldcheckudata(L, 1, "weight", "torch.CudaTensor");
  float normbound = luaL_optnumber(L, 2, 1);

  int kh = weight->size[0];
  int op = weight->size[1];
  int kw = weight->size[2];
  int ip = weight->size[3];
  
  int str0 = weight->stride[0];
  int str1 = weight->stride[1];
  int str2 = weight->stride[2];
  int str3 = weight->stride[3];

  float* wdata=THCudaTensor_data(weight);

  dim3 blocks(op);
  dim3 threads(32);
  
  SCclipWeightsKernel <<<blocks, threads>>>(wdata, normbound, kh, op, kw, ip, str0, str1);

  return 1;
}








static const struct luaL_Reg cunxn_SpatialConvolution__ [] = {
  {"SpatialConvolution_updateOutput", cunxn_SpatialConvolution_updateOutput},
  {"SpatialConvolution_updateGradInput", cunxn_SpatialConvolution_updateGradInput},
  {"SpatialConvolution_accGradParameters", cunxn_SpatialConvolution_accGradParameters},
  {"SpatialConvolution_clipWeights", cunxn_SpatialConvolution_clipWeights},
  {NULL, NULL}
};

static void cunxn_SpatialConvolution_init(lua_State *L)
{
  luaT_pushmetatable(L, "torch.CudaTensor");
  luaT_registeratname(L, cunxn_SpatialConvolution__, "nxn");
  lua_pop(L,1);
}

