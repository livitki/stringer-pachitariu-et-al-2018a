function results = predictNeuronsFromAllBeh(dataroot, matroot, useGPU)

dall=load(fullfile(dataroot, 'dbspont.mat'));

ndims0 = [1 2 3 4 8 16 32 64 128];

clf;
expv_behavior = NaN*ones(length(ndims0),length(dall.db),10);
expvPC_behavior = NaN*ones(128,length(ndims0),length(dall.db),10);


dex = 2;
%%
rng('default');
for d = [1:length(dall.db)]
    %%
    dat = load(fullfile(dataroot,sprintf('spont_%s_%s.mat',dall.db(d).mouse_name,dall.db(d).date)));
    
    if isfield(dat.stat,'redcell')
        Ff = dat.Fsp(~logical([dat.stat(:).redcell]), :);
        med    = dat.med(~logical([dat.stat(:).redcell]),:);
    else
        Ff = dat.Fsp;
        med    = dat.med;
    end
    med = med(sum(Ff,2)>0,:);
    Ff = Ff(sum(Ff,2)>0,:);
        
    tdelay = 1; % optimal time delay
    y    = Ff(:,(tdelay+1):end);
    [NN NT] = size(y);
    disp('>>>>>>>>>>>>> ');
    disp([NN NT]);
    
    % 1.2 second bins
    if dat.db.nplanes == 10
        tbin = 4;
    else
        tbin = 3;
    end
    
    y = bin2d(y, tbin, 2);
    y = y - mean(y,2);

    if useGPU
        [u s v] = svdecon(gpuArray(single(y)));
    else
        [u s v] = svdecon(single(y));
    end
    ncomps  = 128;
    u       = gather_try(u(:, 1:ncomps));% * s(1:ncomps,1:ncomps));
    v       = u' * y;
    
    NT = size(y,2);
    Lblock = round(75);
    fractrain = 0.5;
    [indtrain, indtest] = splitInterleaved(NT, Lblock, fractrain,1);
        
    %% loop over behavioral predictors
    clf;
    for btype = [1:10]
        wmot = dat.beh.whisker.motionSVD(:,1);
        wmot = wmot * sign(mean(mean(dat.beh.whisker.motionMask(:,:,1))));
        switch btype
            %wmot = wmot * sign
            case 1
                x = zscore([dat.beh.runSpeed(:)],1,1);
            case 2
                x = zscore([dat.beh.pupil.area(:)],1,1);
            case 3
                x = zscore([dat.beh.whisker.motionSVD(:,1)],1,1);
            case 4
                x = zscore([dat.beh.runSpeed(:) dat.beh.pupil.area(:)],1,1);
            case 5
                x = zscore([dat.beh.runSpeed(:) wmot],1,1);
            case 6
                x = zscore([dat.beh.pupil.area(:) wmot],1,1);
            case 7
                x = zscore([dat.beh.runSpeed(:) dat.beh.pupil.area(:) wmot],1,1);
            case 8
                x = zscore(dat.beh.face.motionSVD(:,1),1,1);
            case 9
                x = dat.beh.face.motionSVD;
                x = x - mean(x,1);
                x = x / std(x(:,1));
            case 10
                x = dat.beh.face.motionSVD;
                x = x - mean(x,1);
                x = x / std(x(:,1));
                x = [x zscore([dat.beh.runSpeed(:) dat.beh.pupil.area(:) wmot],1,1)];
        end
        
        
        
        x    = x * 10;
        x    = x(1:end-(tdelay),:); % apply time delay
        x    = bin2d(x, tbin, 1);
        x    = x';
        
        if btype == 1
            cc=corr(v(1,:)',x(:));
            v(1,:) = v(1,:) * sign(cc);
            u(:,1) = u(:,1) * sign(cc);
        end
        
        ndims1 = ndims0(ndims0<=size(x,1) & ndims0<=size(v,1));
        
        %% low rank regression
        if size(x,1) > 1
            [a, b] = CanonCor2(v(:,indtrain)', x(:,indtrain)', .05);
            
        else
            b = 1;
            a = v(:,indtrain) * x(:,indtrain)' / (x(:,indtrain)*x(:,indtrain)');
        end
        
        % prediction of correlation matrix
        expv = [];
        ntest = 100;
        expvPC=[];
        for k = 1:length(ndims1)
            n=ndims1(k);
            clear yp;
            vp     = a(:,1:n) * b(:,1:n)' * x(:,indtest);
             
            % residuals of PCs
            vres   = v(:,indtest) - vp;
            expvPC(:,k) = 1 - nanvar(vres,1,2)./nanvar(v(:,indtest),1,2);            
            
            % residuals of neurons
            yp     = u * vp;% + mean(y(:,:),2);
            yres   = y(:,indtest) - yp;
            expv(k) = 1 - nanmean(nanvar(yres,1,2))/nanmean(nanvar(y(:,indtest),1,2));
        end
        yp0=yp;
        semilogx(ndims1,expv,'*-');
        hold all;
        %ylim([0 1]);
        title(max(expv));%dat{d}.db.expt_name{1});
        %ylim([0 .1])
        xlabel(num2str(btype));
        axis tight;
        drawnow;
        
        expv_behavior(1:length(ndims1),d,btype) = expv;
        expvPC_behavior(:,1:length(ndims1),d,btype) = expvPC;
        
        
        
        %%
        if btype == 7
            b(:,1) = b(:,1) * sign(a(1,1));
            a(:,1) = a(:,1) * sign(a(1,1));
            c1d(:,d) = b(:,1);
            xtest1d{d} = x(:,indtest);
            n1d(:,d) = a(:,1);
            umat{d} = u;
            
            ccarousal{d} = corr(y',x');
        end
        
        %% sort data by 1D embedding
        if btype == 9
            if d == dex
                nC=30;
                [~,isort] = sort(u(:,1));
                [iclust,isort] = embed1D(zscore(y(:,indtest),1,2),nC,isort,useGPU);
                yt = y(isort,indtest);
                ytstd = max(1e-3,std(yt,1,2));
                yt = yt ./ ytstd;
                yp = yp0(isort,:) ./ ytstd;
            
                yt = my_conv2(yt,6,1);
                yp = my_conv2(yp,1,1);
                ccembed(d) = corr(yt(:),yp(:));
                disp(ccembed);

                vtest{d} = v(:,indtest);
                vpred{d} = vp;
                ypred{d} = yp0;
                ytest{d} = y(:,indtest);
                isortembed{d} = isort;
                aface = a(:,1:16);
                bface = b(:,1:16);
                xtest{d} = x(1:1000,indtest);
            end
        end
        
        
        
        
    end
    
    cellpos{d} = med;
end

c1d=real(c1d);

%%
save(fullfile(matroot,'expv_behavior_neurons.mat'),'-v7.3','expv_behavior','expvPC_behavior','ndims0',...
    'c1d','n1d','vtest','xtest1d','vpred','ypred','umat','ytest','xtest','aface','bface',...
    'isortembed','ccembed','cellpos','ccarousal');















