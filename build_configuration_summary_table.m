function summaryTable = build_configuration_summary_table(configurations)
% BUILD_CONFIGURATION_SUMMARY_TABLE
%
% A teljes konfiguracios adatbazisbol gyorsan szurheto summary tablat keszit.

    n = numel(configurations);

    id = strings(n,1);
    outputFile = strings(n,1);

    PV_scale = NaN(n,1);
    E_BESS_kWh = NaN(n,1);
    P_BESS_kW = NaN(n,1);
    P_inv_kW = NaN(n,1);
    P_DG_kW = NaN(n,1);

    wasSimulated = false(n,1);
    hasError = false(n,1);
    errorMessage = strings(n,1);

    LPSP = NaN(n,1);
    loadEnergy_kWh = NaN(n,1);
    servedEnergy_kWh = NaN(n,1);
    unservedEnergy_kWh = NaN(n,1);
    dieselToLoad_kWh = NaN(n,1);
    dieselFuel_liter = NaN(n,1);
    curtailment_kWh = NaN(n,1);
    inverterLoss_kWh = NaN(n,1);
    internalNetworkLoss_kWh = NaN(n,1);
    totalCost_HUF = NaN(n,1);
    LCOE_HUF_per_kWh = NaN(n,1);
    isFeasible = false(n,1);

    for i = 1:n

        c = configurations(i);

        id(i) = string(c.id);
        outputFile(i) = string(c.outputFile);

        if isfield(c, 'design') && ~isempty(fieldnames(c.design))
            PV_scale(i) = c.design.PV_scale;
            E_BESS_kWh(i) = c.design.E_BESS_kWh;
            P_BESS_kW(i) = c.design.P_BESS_kW;
            P_inv_kW(i) = c.design.P_inv_kW;
            P_DG_kW(i) = c.design.P_DG_kW;
        end

        wasSimulated(i) = c.status.wasSimulated;
        hasError(i) = c.status.hasError;
        errorMessage(i) = string(c.status.message);

        if isfield(c, 'metrics') && isfield(c.metrics, 'LPSP')
            LPSP(i) = c.metrics.LPSP;
            loadEnergy_kWh(i) = c.metrics.loadEnergy_kWh;
            servedEnergy_kWh(i) = c.metrics.servedEnergy_kWh;
            unservedEnergy_kWh(i) = c.metrics.unservedEnergy_kWh;
            dieselToLoad_kWh(i) = c.metrics.dieselToLoad_kWh;
            dieselFuel_liter(i) = c.metrics.dieselFuel_liter;
            curtailment_kWh(i) = c.metrics.curtailment_kWh;
            inverterLoss_kWh(i) = c.metrics.inverterLoss_kWh;
            internalNetworkLoss_kWh(i) = c.metrics.internalNetworkLoss_kWh;
            isFeasible(i) = c.metrics.isFeasible;
        end

        if isfield(c, 'costs') && isfield(c.costs, 'totalCost_HUF')
            totalCost_HUF(i) = c.costs.totalCost_HUF;
            LCOE_HUF_per_kWh(i) = c.costs.LCOE_HUF_per_kWh;
        end
    end

    summaryTable = table();

    summaryTable.id = id;
    summaryTable.outputFile = outputFile;

    summaryTable.PV_scale = PV_scale;
    summaryTable.E_BESS_kWh = E_BESS_kWh;
    summaryTable.P_BESS_kW = P_BESS_kW;
    summaryTable.P_inv_kW = P_inv_kW;
    summaryTable.P_DG_kW = P_DG_kW;

    summaryTable.wasSimulated = wasSimulated;
    summaryTable.hasError = hasError;
    summaryTable.errorMessage = errorMessage;

    summaryTable.LPSP = LPSP;
    summaryTable.loadEnergy_kWh = loadEnergy_kWh;
    summaryTable.servedEnergy_kWh = servedEnergy_kWh;
    summaryTable.unservedEnergy_kWh = unservedEnergy_kWh;
    summaryTable.dieselToLoad_kWh = dieselToLoad_kWh;
    summaryTable.dieselFuel_liter = dieselFuel_liter;
    summaryTable.curtailment_kWh = curtailment_kWh;
    summaryTable.inverterLoss_kWh = inverterLoss_kWh;
    summaryTable.internalNetworkLoss_kWh = internalNetworkLoss_kWh;

    summaryTable.totalCost_HUF = totalCost_HUF;
    summaryTable.LCOE_HUF_per_kWh = LCOE_HUF_per_kWh;
    summaryTable.isFeasible = isFeasible;
end