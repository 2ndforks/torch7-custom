local SpatialConvolution, parent = torch.class('nxn.SpatialConvolution', 'nxn.Module')


function SpatialConvolution:__init(nInputPlane, nOutputPlane, kW, kH, dW, dH, padleft, padright, padtop, padbottom)
   parent.__init(self)

   dW = dW or 1
   dH = dH or 1

   self.nInputPlane = nInputPlane
   self.nOutputPlane = nOutputPlane
   self.kW = kW
   self.kH = kH
   self.dW = dW
   self.dH = dH
   self.padleft = padleft or 0
   self.padright = padright or 0
   self.padtop = padtop or 0
   self.padbottom = padbottom or 0
   self.overlap = overlap or 0
   self.addgrads=0
   self.tmpweight=torch.Tensor()
   self.tmpgradweight=torch.Tensor()

   self.alpha= alpha or 1
   self.beta= beta or 0

   self.weight = torch.Tensor(nOutputPlane, kH, kW, nInputPlane)
   self.bias = torch.Tensor(nOutputPlane)

   self.gradWeight = torch.Tensor(nOutputPlane, kH, kW, nInputPlane):zero()
   self.gradBias = torch.Tensor(nOutputPlane):zero()
   
--   self.memoryWeight = torch.Tensor(nOutputPlane):zero()
--   self.memoryBias = torch.Tensor(nOutputPlane):zero()
   
--   self.memoryWeight = torch.Tensor(nOutputPlane, kH, kW, nInputPlane):fill(1e-10)
--   self.memoryBias = torch.Tensor(nOutputPlane):fill(1e-10)
   
--   self.adaRateWeight = torch.Tensor(nOutputPlane, kH, kW, nInputPlane):zero()
--   self.adaRateBias = torch.Tensor(nOutputPlane):zero()
   
   self.adaptiveLR = false
   self.masterLR=nil
   
   self:reset()
   
   self.mode='conv' -- can be : 'conv', 'trivial', 'fc'
   self.learningRate=0
   self.momentum=0
   self.weightDecay=0
end

function SpatialConvolution:setLearningRate(lr)
   if lr > 0 or lr==0 then
      self.learningRate=lr
   else
      error('learning rate must be positive or 0')   
   end
end

function SpatialConvolution:setMomentum(mom)
   if mom > 0 or mom==0 then
      self.momentum=mom
   else
      error('momentum must be positive or 0')   
   end
end

function SpatialConvolution:setWeightDecay(wd)
   if wd > 0 or wd==0 then
      self.weightDecay=wd
   else
      error('weight decay must be positive or 0')   
   end
end

function SpatialConvolution:reset(stdv)
   if stdv then
      stdv = stdv
   else
      stdv = 1/math.sqrt(self.kW*self.kH*self.nInputPlane)
   end
   torch.randn(self.weight, self.weight:size())
   self.weight:mul(stdv)
   torch.randn(self.bias, self.bias:size())
   self.bias:mul(stdv)
end








-- these functions are necessary because switching from one mode to another
-- requires a hard transpose.
-- should stick to a standard format, and copy kernels during convolution forward step
-- but well...

function SpatialConvolution:switchToFC()
   if self.mode=='fc' then return end
   if self.mode=='conv' then 
--      self.weight=self.weight:transpose(1,2):contiguous()
--      self.gradWeight=self.gradWeight:transpose(1,2):contiguous()
--      assert(self.weight:size(1)==self.nOutputPlane) -- just checkin'
      self.mode='fc'
--      print('switched layer to dense mode (kernel size == image size, no padding)')
      return
   end
end

function SpatialConvolution:switchToConv()
   if self.mode=='conv' then return end
   if self.mode=='fc' then 
--      self.weight=self.weight:transpose(1,2):contiguous()
--      self.gradWeight=self.gradWeight:transpose(1,2):contiguous()
--      assert(self.weight:size(1)==self.kH) -- just checkin'
      self.mode='conv'
--      print('switched layer to convolution mode (kernel size < image size)')
      return
   end
end

function SpatialConvolution:switchToTrivial()
   if self.mode=='trivial' then return end
   assert(self.kH==1 and self.kW==1 and self.dH==1 and self.dW==1)
   self.weight=self.weight:contiguous()
   self.gradWeight=self.gradWeight:contiguous()
   self.weight=self.weight:resize(self.nOutputPlane, self.nInputPlane)
   self.gradWeight=self.gradWeight:resize(self.nOutputPlane, self.nInputPlane)
   self.mode='trivial' -- no-return point.
--   print('switched layer to trivial mode (1x1 kernel, no padding)')
end

function SpatialConvolution:optimize(input)
   if self.padleft==0 and 
      self.padright==0 and 
      self.padtop==0 and 
      self.padbottom==0 and
      self.kH==1 and 
      self.kW==1 and 
      self.dH==1 and 
      self.dW==1 then 
      -- critical step : add pcall here
      self:switchToTrivial()
      return
   end
   if self.padleft==0 and 
      self.padright==0 and 
      self.padtop==0 and 
      self.padbottom==0 and 
      input:size(2)==self.kH and
      input:size(3)==self.kW and
      input:size(4)==self.nInputPlane then 
      -- critical step : add pcall here
      self:switchToFC()
      return
   end 
      -- critical step : add pcall here
      self:switchToConv()
   return
end







-- update outputs

function SpatialConvolution:updateOutputTrivial(input)
   -- input is flattened (view)
   local tinput=input.new()
   tinput:set(input:storage(), 1, torch.LongStorage{input:size(1)*input:size(2)*input:size(3), input:stride(3)})
   
   -- weight is flattened (view)
   local tweight=self.weight
   
   -- MM
   self.output:resize(input:size(1)*input:size(2)*input:size(3), self.weight:size(1))
   self.output:zero():addr(1, input.new(input:size(1)*input:size(2)*input:size(3)):fill(1), self.bias)
   self.output:addmm(1, tinput, tweight:t())

   -- output is unflattened
   self.output:resize(input:size(1), input:size(2), input:size(3), self.weight:size(1))
--   print('updateOutputTrivial')
end

function SpatialConvolution:updateOutputFC(input)
   -- input is flattened (view)
   local tinput=input.new()
   tinput:set(input:storage(), 1, torch.LongStorage{input:size(1), input:stride(1)})
   
   -- weight is flattened (view)
   local tweight=self.weight.new()
   tweight:set(self.weight:storage(), 1, torch.LongStorage{self.weight:size(1), self.weight:stride(1)})
   
   -- MM
   self.output:resize(input:size(1), self.weight:size(1))
   self.output:zero():addr(1, input.new(input:size(1)):fill(1), self.bias)
   self.output:addmm(1, tinput, tweight:t())
   self.output:resize(input:size(1), 1, 1, self.weight:size(1))
--   print('updateOutputFC')
end

function SpatialConvolution:updateOutputConv(input)
   input.nxn.SpatialConvolution_updateOutput(self, input)
--   print('updateOutputConv')
end

function SpatialConvolution:updateOutput(input)
   if input:size(2)+self.padtop+self.padbottom<self.kH or input:size(3)+self.padleft+self.padright<self.kW then error ('input is too small') end
   self:optimize(input)
   if self.mode=='trivial' then self:updateOutputTrivial(input) end
   if self.mode=='fc' then self:updateOutputFC(input) end
   if self.mode=='conv' then self:updateOutputConv(input) end
   return self.output
end







-- update gradients

function SpatialConvolution:updateGradInputTrivial(input, gradOutput)
   -- gradOutput is flattened (view)
   local tgradOutput=gradOutput.new()
   tgradOutput:set(gradOutput:storage(), 1, torch.LongStorage{gradOutput:size(1)*gradOutput:size(2)*gradOutput:size(3), gradOutput:stride(3)})
  
   local tweight=self.weight

   local nElement = self.gradInput:nElement()
   self.gradInput:resizeAs(input)

   self.gradInput:resizeAs(input)
   if self.gradInput:nElement() ~= nElement then
      self.gradInput:zero()
   end

   -- gradInput is flattened (view)
   local tgradInput=self.gradInput.new()
   tgradInput:set(self.gradInput:storage(), 1, torch.LongStorage{self.gradInput:size(1)*self.gradInput:size(2)*self.gradInput:size(3), self.gradInput:stride(3)})

   tgradInput:addmm(0, 1, tgradOutput, tweight)
   
end

function SpatialConvolution:updateGradInputFC(input, gradOutput)
   -- gradOutput is flattened (view)
   local tgradOutput=gradOutput.new()
   tgradOutput:set(gradOutput:storage(), 1, torch.LongStorage{gradOutput:size(1), gradOutput:stride(1)})
   
   -- weight is flattened (view)
   local tweight=self.weight.new()
   tweight:set(self.weight:storage(), 1, torch.LongStorage{self.weight:size(1), self.weight:stride(1)})
   
   local nElement = self.gradInput:nElement()
   self.gradInput:resizeAs(input)
   if self.gradInput:nElement() ~= nElement then
      self.gradInput:zero()
   end

   -- gradInput is flattened (view)
   local tgradInput=self.gradInput.new()
   tgradInput:set(self.gradInput:storage(), 1, torch.LongStorage{self.gradInput:size(1), self.gradInput:stride(1)})

   tgradInput:addmm(0, 1, tgradOutput, tweight)

end

function SpatialConvolution:updateGradInputConv(input, gradOutput)
   input.nxn.SpatialConvolution_updateGradInput(self, input, gradOutput)
end

function SpatialConvolution:updateGradInput(input, gradOutput)
   self:optimize(input)
   if self.doBackProp then 
      if self.mode=='trivial' then self:updateGradInputTrivial(input, gradOutput) end
      if self.mode=='fc' then self:updateGradInputFC(input, gradOutput) end
      if self.mode=='conv' then self:updateGradInputConv(input, gradOutput) end
      return self.gradInput
   end
end







-- update weight gradients

function SpatialConvolution:zeroGradParameters()
   self.gradWeight:zero()
   self.gradBias:zero()
end

function SpatialConvolution:accGradParametersTrivial(input, gradOutput, scale)
   -- input is flattened (view)
   local tinput=input.new()
   tinput:set(input:storage(), 1, torch.LongStorage{input:size(1)*input:size(2)*input:size(3), input:stride(3)})
   -- gradOutput is flattened (view)
   local tgradOutput=gradOutput.new()
   tgradOutput:set(gradOutput:storage(), 1, torch.LongStorage{gradOutput:size(1)*gradOutput:size(2)*gradOutput:size(3), gradOutput:stride(3)})
   
   self.gradWeight:addmm(scale, tgradOutput:t(), tinput)
   self.gradBias:addmv(scale, tgradOutput:t(), tinput.new(input:nElement()/self.weight:size(2)):fill(1))
      
end

function SpatialConvolution:accGradParametersFC(input, gradOutput, scale)
   -- input is flattened (view)
   local tinput=input.new()
   tinput:set(input:storage(), 1, torch.LongStorage{input:size(1), input:stride(1)})

   -- gradOutput is flattened (view)
   local tgradOutput=gradOutput.new()
   tgradOutput:set(gradOutput:storage(), 1, torch.LongStorage{gradOutput:size(1), gradOutput:stride(1)})
   
   -- weight is flattened (view)
   local tgradWeight=self.gradWeight.new()
   tgradWeight:set(self.gradWeight:storage(), 1, torch.LongStorage{self.gradWeight:size(1), self.gradWeight:stride(1)})

   tgradWeight:addmm(scale, tgradOutput:t(), tinput)
   self.gradBias:addmv(scale, tgradOutput:t(), tinput.new(input:size(1)):fill(1))

end

function SpatialConvolution:accGradParametersConv(input, gradOutput, scale)
   input.nxn.SpatialConvolution_accGradParameters(self, input, gradOutput, scale) 
end

function SpatialConvolution:accGradParameters(input, gradOutput, scale)
   if self.learningRate > 0 or self.adaptiveLR then 
      self:optimize(input)
      if not gradOutput then error('Y U NO gradOutput ???') end
      local scale = 1 / input:size(1)
      self:applyMomentum()
      if self.mode=='trivial' then self:accGradParametersTrivial(input, gradOutput, scale) end
      if self.mode=='fc' then self:accGradParametersFC(input, gradOutput, scale) end
      if self.mode=='conv' then self:accGradParametersConv(input, gradOutput, scale) end
      self:applyWeightDecay()
   end
--    return 
end


function SpatialConvolution:needGradients()
   return (self.learningRate > 0 or self.adaptiveLR)
end

function SpatialConvolution:updateParameters()
   if self.learningRate > 0 or self.adaptiveLR then
      if self.adaptiveLR then
         self:computeRates()
         self.weight:addcmul(-1, self.adaRateWeight, self.gradWeight)
         self.bias:addcmul(-1, self.adaRateBias, self.gradBias)
         return
      else
         self.weight:add(-1*self.learningRate, self.gradWeight)
         self.bias:add(-1*self.learningRate, self.gradBias)
         return
      end
   end
end

function SpatialConvolution:applyMomentum()
   self.gradWeight:mul(self.momentum)
   self.gradBias:mul(self.momentum)
end

function SpatialConvolution:applyWeightDecay()
   self.gradWeight:add(self.weightDecay, self.weight)
   self.gradBias:add(self.weightDecay, self.bias)
end


--SpatialConvolution:__init(nInputPlane, nOutputPlane, kW, kH, dW, dH, padleft, padright, padtop, padbottom)

local function tensorsizestring(t)
   local str = t:type() .. ' - '
   if t:dim()>0 then
      for i=1,t:dim()-1 do
         str = str .. t:size(i) .. 'x'
      end	
      str = str .. t:size(t:dim())
   else 
      str = str .. 'empty'
   end
   return str
end

function nxn.SpatialConvolution:__tostring__()
   local tab = '     |  '
   local line = '\n'
   local next = ' -> '
   local str = 'nxn.SpatialConvolution('
   str = str .. self.nInputPlane ..', '
   str = str .. self.nOutputPlane ..', '
   str = str .. self.kW ..', '
   str = str .. self.kH ..', '
   str = str .. self.dW ..', '
   str = str .. self.dH ..', '
   str = str .. self.padleft ..', '
   str = str .. self.padright ..', '
   str = str .. self.padtop ..', '
   str = str .. self.padbottom ..')'
   str = str .. line .. tab
   str = str .. 'name        : '.. (self.name or '')
   str = str .. line .. tab
   str = str .. 'params      : LR : '.. self.learningRate ..', momentum : ' .. self.momentum ..', weight decay : '.. self.weightDecay
   str = str .. line .. tab
   str = str .. 'output      : ' .. tensorsizestring(self.output)
   --str = str .. line .. tab
   --str = str .. 'gradInput   : ' .. tensorsizestring(self.gradInput)
   str = str .. line

   return str
end


function nxn.SpatialConvolution:autoLR(masterLR)
   self.masterLR=masterLR or 1e-3
   self.adaptiveLR=true
end


function nxn.SpatialConvolution:computeRates()
   if not self.adaRateWeight then
      self.adaRateWeight=self.weight.new(#self.weight):zero()
   end
   if not self.adaRateBias then
      self.adaRateBias=self.bias.new(#self.bias):zero()
   end
   if not self.memoryWeight then
      self.memoryWeight=self.weight.new(#self.weight):fill(1e-10)
   end
   if not self.memoryBias then
      self.memoryBias=self.bias.new(#self.bias):fill(1e-10)
   end
   self.adaRateWeight:fill(1)
   self.adaRateBias:fill(1)
   self.memoryWeight:addcmul(self.gradWeight, self.gradWeight)
   self.memoryBias:addcmul(self.gradBias, self.gradBias)
   self.adaRateWeight:cdiv(self.memoryWeight):sqrt():mul(self.masterLR)
   self.adaRateBias:cdiv(self.memoryBias):sqrt():mul(self.masterLR)
end




-- clip the weights (this is for later)

function SpatialConvolution:clipWeights(normbound)
   for idx=1,self.nOutputPlane do
      local filternorm=self.weight:select(2,idx):norm()
      if filternorm > normbound then
         self.weight:select(2,idx):mul(normbound/filternorm)
      end
   end
end

function SpatialConvolution:clipWeights(normbound)
   self.weight.nxn.SpatialConvolution_clipWeights(self, normbound)
end

