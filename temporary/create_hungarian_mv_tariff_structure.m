function tariff = create_hungarian_mv_tariff_structure()

    tariff = struct();

    tariff.class_name = 'Kozepfeszultsegu csatlakozas';

    tariff.distribution_energy_rate_huf_per_kWh = 8.39;
    tariff.transmission_energy_rate_huf_per_kWh = 3.39;

    tariff.annual_contracted_power_fee_huf_per_kW = 15924;
    tariff.annual_base_fee_huf = 216504;

    tariff.contracted_capacity_kW = 350;

    tariff.days_in_year = 365;
    tariff.months_in_year = 12;

    % túllépési díj éves megfelelőből számolva
    tariff.penalty_rate_huf_per_kW_year = 4.0 * tariff.annual_contracted_power_fee_huf_per_kW;

    tariff.grid_charge_price_quantile = 0.25;
    tariff.noncheap_charge_penalty_huf_per_kWh = 0.0;

    tariff.peak_reserve_soc = 0.50;
    tariff.peak_hours = [16, 22];

    tariff.curtailment_penalty_huf_per_kWh = 0.0;

    % csak opcionális tie-break, alapból 0
    tariff.within_contract_peak_weight_huf_per_kW_month = 0.0;
end