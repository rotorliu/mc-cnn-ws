require 'nn'
require 'cunn'
mcCnnFst = dofile('CMcCnnFst.lua')
dofile('CAddMatrix.lua')
require 'libdynprog'
dofile('CDynProg.lua')
dofile('CContrastDynProgMax.lua')


disp_max = 200
img_w = 1000
hpatch = 4
max_order = 3
fnet, hpatch = mcCnnFst.get(4, 64, 3)
dist_min = 2
local fNetRef = fnet:clone();
 
local Net = nn.Sequential()


-- pass 3 epipolar lines through feature net and normalize outputs
local fNets = nn.ParallelTable()
Net:add(fNets)  -- parallel feature nets
fNetRef:add(nn.Squeeze(2))
fNetRef:add(nn.Transpose({1,2}))
fNetRef:add(nn.Normalize(2))
local fNetPos = fNetRef:clone('weight','bias', 'gradWeight','gradBias');
local fNetNeg = fNetRef:clone('weight','bias', 'gradWeight','gradBias');
fNets:add(fNetRef)
fNets:add(fNetPos)
fNets:add(fNetNeg)

-- compute 3 cross products: ref and pos, ref and neg, pos and neg
local fNets2dNetCom = nn.ConcatTable()
Net:add(fNets2dNetCom); -- feature net to distance net commutator
local dNetRefPos_ = nn.Sequential()
local dNetRefNeg = nn.Sequential()
local dNetNegPos = nn.Sequential()
fNets2dNetCom:add(dNetRefPos_)
fNets2dNetCom:add(dNetRefNeg)
fNets2dNetCom:add(dNetNegPos)
local dNetRefPosSel = nn.ConcatTable()  -- input selectors for each distance net
local dNetRefNegSel = nn.ConcatTable()
local dNetNegPosSel = nn.ConcatTable()
dNetRefPos_:add(dNetRefPosSel)
dNetRefNeg:add(dNetRefNegSel)
dNetNegPos:add(dNetNegPosSel)
dNetRefPosSel:add(nn.SelectTable(1))
dNetRefPosSel:add(nn.SelectTable(2))
dNetRefNegSel:add(nn.SelectTable(1))
dNetRefNegSel:add(nn.SelectTable(3))
dNetNegPosSel:add(nn.SelectTable(3))
dNetNegPosSel:add(nn.SelectTable(2))
dNetRefPos_:add(nn.MM(false, true))
dNetRefNeg:add(nn.MM(false, true))
dNetNegPos:add(nn.MM(false, true))

-- mask distance matrices to leave only valid disparities
-- Basically we substract 2 from elements that should be ignored.
-- In this way we make these elements much smaller than other elements.
local mask = torch.ones(img_w-2*hpatch, img_w-2*hpatch)*2  
mask = torch.triu(torch.tril(mask,-1),-disp_max)
mask = mask - 2; 
dNetRefPos_:add(nn.addMatrix(mask))
dNetRefNeg:add(nn.addMatrix(mask))
dNetNegPos:add(nn.addMatrix(mask))

-- make 2 copies of refPos distance matrix, since we use will use it twice 
-- as ref-pos and pos-ref
dNetRefPos_:add(nn.Replicate(2))
dNetRefPos_:add(nn.SplitTable(1))
local dNetRefPosSpl_ = nn.ParallelTable() -- splitter for ref-pos distance matrix
dNetRefPos_:add(dNetRefPosSpl_)
local dNetRefPos = nn.Sequential()
local dNetPosRef = nn.Sequential()
dNetRefPosSpl_:add(dNetRefPos)
dNetRefPosSpl_:add(dNetPosRef)

-- now cut parts of distance matrices, that correspond to edges of the image
-- since on the edges of the image we might not have correct matches
-- ref-neg table we cut from the top, and take max along 2 dim
dNetRefNeg:add(nn.Narrow(1, disp_max+1, img_w - 2*hpatch - disp_max))
-- neg-pos table we cut from the right, transpose and take max along 2 dim
dNetNegPos:add(nn.Narrow(2, 1, img_w - 2*hpatch - disp_max))
dNetNegPos:add(nn.Transpose{1,2})
-- ref-pos we cut from the top
dNetRefPos:add(nn.Narrow(1, disp_max+1, img_w - 2*hpatch - disp_max))
-- second copy of ref-pos we cut from the right and transpose to obtain pos-ref
dNetPosRef:add(nn.Narrow(2, 1, img_w - 2*hpatch - disp_max))
dNetPosRef:add(nn.Transpose{1,2})

-- find best dprog solution for ref-neg and neg-pos
dNetRefNeg:add(nn.dynProg(dist_min))
dNetNegPos:add(nn.dynProg(dist_min))

-- find dprog solution for ref-pos and pos-ref
-- and alternative max solution that is on minimum distance from dprog solution
dNetRefPos:add(nn.contrastDynProgMax(dist_min))
dNetRefPos:add(nn.SplitTable(2))
dNetPosRef:add(nn.contrastDynProgMax(dist_min))
dNetPosRef:add(nn.SplitTable(2))

---- flatten tables hierarchy
---- after flattening, order is following 
---- ref-pos-dprog, ref-pos-max, pos-ref-dprog, pos-ref-max, ref-neg-dprog, pos-neg-dprog
Net:add(nn.FlattenTable())

-- make 4 output tables of tables
local dNet2CostCom = nn.ConcatTable()
Net:add(dNet2CostCom); -- feature net to distance net commutator
local milFwd = nn.Sequential()
local milBwd = nn.Sequential()
local contrastFwd = nn.Sequential()
local contrastBwd = nn.Sequential()
dNet2CostCom:add(milFwd)
dNet2CostCom:add(milBwd)
dNet2CostCom:add(contrastFwd)
dNet2CostCom:add(contrastBwd)
local milFwdSel = nn.ConcatTable()  -- input selectors for cost
local milBwdSel = nn.ConcatTable()
local contrastFwdSel = nn.ConcatTable()  -- input selectors for each distance net
local contrastBwdSel = nn.ConcatTable()
milFwd:add(milFwdSel)
milBwd:add(milBwdSel)
contrastFwd:add(contrastFwdSel)
contrastBwd:add(contrastBwdSel)
milFwdSel:add(nn.SelectTable(1))  -- ref-pos-dprog
milFwdSel:add(nn.SelectTable(5))  -- ref-neg-dprog
milBwdSel:add(nn.SelectTable(3))  -- pos-ref-dprog
milBwdSel:add(nn.SelectTable(6))  -- ref-neg-dprog
contrastFwdSel:add(nn.SelectTable(1))  -- ref-pos-dprog
contrastFwdSel:add(nn.SelectTable(2))  -- ref-pos-max
contrastBwdSel:add(nn.SelectTable(3))  -- ref-pos-dprog
contrastBwdSel:add(nn.SelectTable(4))  -- ref-pos-max

-- cpu
start_cpu = os.time()
input_cpu = {torch.rand(1,2*hpatch+1,img_w), torch.rand(1,2*hpatch+1,img_w), torch.rand(1,2*hpatch+1,img_w)};
output_cpu = Net:forward(input_cpu);
end_cpu = os.time()
print(os.difftime(end_cpu, start_cpu))


-- cuda
input = {torch.rand(1,2*hpatch+1,img_w):cuda(), torch.rand(1,2*hpatch+1,img_w):cuda(), torch.rand(1,2*hpatch+1,img_w):cuda()};
Net:cuda()
start_gpu = os.time()
output_gpu = Net:forward(input)
end_gpu = os.time()
print(os.difftime(end_gpu, start_gpu))

criOut = parCri:forward(netOut, targ)
outGradCri = parCri:backward(netOut, targ)
  
--Net:backward(netIn, parCri:backward(criIn, criTarg))

--outcrit = criterion:forward(output,torch.Tensor{1})
