local ExtractInterpolate, parent = torch.class('nxn.ExtractInterpolate', 'nxn.Module')
-- this is a general class for extraction stuff
-- jitter / resize modules should inherit this class

local help_str = 
[[This is the generic extract/interpolate module. It uses textures on GPU.
It takes an arbitrarily-shaped quadrilateral (by choosing 4 corners) of an RGB image and bilinearly interpolates it to the target size.

Usage : m = nxn.ExtractInterpolate()
m:updateOutputCall(input, targety, targetx, y1, x1, y2, x2, y3, x3, y4, x4)

Where : targety, targetx : size of output
y1,x1 = input pixel corresponding to top left corner of output
y2,x2 = input pixel corresponding to top right corner of output
y3,x3 = input pixel corresponding to bottom right corner of output
y4,x4 = input pixel corresponding to bottom left corner of output

It only works in BATCH MODE (4D) with RGB inputs :
- with the following input layout : (batch, y, x, RGB).
- RGB are the contiguous dimension.
- a single image must be a (1, y, x, RGB) tensor.

The module doesn't require fixed-size inputs.]]

function ExtractInterpolate:__init()
   parent.__init(self)
   
   -- we need this for the texture
   self.tmp=torch.Tensor()
   self.gpucompatible = true
end

function ExtractInterpolate:updateOutput(input)
   return self.output
end


function ExtractInterpolate:updateGradInput(input, gradOutput)
   return 
end

function ExtractInterpolate:updateOutputCall(input, targety, targetx, y1, x1, y2, x2, y3, x3, y4, x4)
   -- targety, targetx : size of output
   self.targety=targety
   self.targetx=targetx

   -- y1,x1 = input pixel corresponding to top left corner of output
   -- y2,x2 = input pixel corresponding to top right corner of output
   -- y3,x3 = input pixel corresponding to bottom right corner of output
   -- y4,x4 = input pixel corresponding to bottom left corner of output
   self.y1=y1
   self.y2=y2
   self.y3=y3
   self.y4=y4
   self.x1=x1
   self.x2=x2
   self.x3=x3
   self.x4=x4

   --self.output:resize(input:size(1), self.targety, self.targetx, input:size(4))
   input.nxn.ExtractInterpolate_updateOutput(self, input)
   
   collectgarbage()

   return 
end

function ExtractInterpolate:getDisposableTensors()
   return {self.output, self.gradInput, self.tmp}
end










