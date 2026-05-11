function [pack_out, pack_state] = bess_pack_model(P_pack_req, mode, pack_params, dt_h, pack_state)
    % BESS_PACK_MODEL - Kereskedelmi standard feszültséglépcsők és kWh alapú méretezés
    
    if strcmp(mode, 'init')
        % --- 1. Paraméterek beolvasása ---
        E_target_kWh = pack_params.target_energy_kWh;
        P_max_W      = pack_params.max_power_W;
        
        % Standard cella adatok (280Ah prizmatikus LFP)
        CELL_AH    = 280;
        CELL_V_NOM = 3.2;
        CELL_KWH   = (CELL_AH * CELL_V_NOM) / 1000; % ~0.896 kWh
        
        % --- 2. Soros cellák száma (Ns) kiválasztása (Kereskedelmi standardok) ---
        % A teljesítményigény határozza meg a feszültségszintet a valóságban is
        if P_max_W <= 10000
            Ns = 16;  % Standard 48V-os kisfeszültségű rendszer (ELV)
        elseif P_max_W <= 50000
            Ns = 64;  % Közepes feszültségű ipari rendszer (~200V)
        else
            Ns = 128; % Nagyfeszültségű ipari/közmű hálózati rendszer (400V+)
        end
        
        % --- 3. Párhuzamos ágak száma (Np) az energiacél alapján ---
        % Egy soros ág (string) energiája a választott Ns mellett
        E_string_kWh = Ns * CELL_KWH;
        
        % Kiszámoljuk hány ilyen string kell a célenergia eléréséhez
        Np = round(E_target_kWh / E_string_kWh);
        Np = max(1, Np); % Legalább egy ág mindenképpen kell
        
        % Ténylegesen beépített energia kalkulációja a diszkrét elemszámok miatt
        E_installed_kWh = Np * E_string_kWh;
        V_nominal_pack  = Ns * CELL_V_NOM;
        
        % --- 4. Inicializálás ---
        pack_state = struct();
        pack_state.Ns = Ns;
        pack_state.Np = Np;
        pack_state.E_installed_kWh = E_installed_kWh;
        
        % Cella állapot inicializálása (homogén cellák)
        cell_params = struct('C_nom_Ah', CELL_AH, 'initial_soc', pack_params.initial_soc);
        [~, cell_init_state] = lfp_cell(0, 'init', cell_params, dt_h, []);
        pack_state.cell_state = cell_init_state;
        
        % Rendszeradatok visszaadása az első híváskor
        pack_out = struct('Ns', Ns, 'Np', Np, ...
                         'V_nominal_pack', V_nominal_pack, ...
                         'E_installed_kWh', E_installed_kWh, ...
                         'Total_cells', Ns * Np);
        return;

    elseif strcmp(mode, 'run')
        % --- Futtatási fázis ---
        Ns = pack_state.Ns;
        Np = pack_state.Np;
        
        % Teljesítmény leosztása egyetlen cellára
        P_req_cell_vec = P_pack_req / (Ns * Np);
        
        % Cella modell futtatása (Dinamikus hőmodellel és veszteségekkel)
        cell_params.T_vec = pack_params.T_vec;
        [cell_out, next_cell_state] = lfp_cell(P_req_cell_vec, 'run', cell_params, dt_h, pack_state.cell_state);
        
        % --- Eredmények skálázása a teljes akkupakkra ---
        pack_out = struct();
        pack_out.V_pack = cell_out.Ut * Ns;             % Aktuális kapocsfeszültség [V]
        pack_out.I_pack = cell_out.I_cell * Np;         % Aktuális áramfolyam [A]
        pack_out.SOC    = cell_out.SOC;                 % Töltöttségi szint
        pack_out.T_cell = cell_out.T_cell;              % Cella belső hőmérséklet
        
        % Energia összesítések (Wh)
        pack_out.E_stored      = cell_out.E_stored * Ns * Np;
        pack_out.E_discharged  = cell_out.E_discharged * Ns * Np;
        pack_out.E_loss_joule  = cell_out.E_loss_joule * Ns * Np;
        pack_out.E_loss_sat    = cell_out.E_loss_sat * Ns * Np;
        pack_out.E_loss_empty  = cell_out.E_loss_empty * Ns * Np;
        pack_out.SOH           = cell_out.SOH;
        
        % Állapot frissítése
        pack_state.cell_state = next_cell_state;
    end
end