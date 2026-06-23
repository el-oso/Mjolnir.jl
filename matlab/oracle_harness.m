function oracle_harness()
% oracle_harness - MATLAB oracle harness for Mjolnir CI.
%
% Reads manifest.json from the current working directory, executes each case
% in an ISOLATED function workspace (run_one_case), so variables created by one
% case (s, f, ...) cannot leak into and collide with a later case. This mirrors
% the Octave path, which runs each snippet in a fresh subprocess.
%
% Each case is wrapped in try/catch (so one failure records an error marker
% instead of aborting the batch), harvests the requested variables via
% jsonencode, and writes matlab_results.json.
%
% Usage (from matlab-actions/run-command):
%   cd('<workdir>'); oracle_harness
%
% Output format (matlab_results.json):
%   { "<id>": { "<var>": <json_value>, ... }, ... }
% On per-case failure:
%   { "<id>": { "run_error": "<message>" }, ... }

fprintf('oracle_harness: reading manifest.json\n');
mh_manifest_text = fileread('manifest.json');
mh_manifest = jsondecode(mh_manifest_text);

mh_results = struct();

mh_n_cases = numel(mh_manifest);
fprintf('oracle_harness: %d cases to run\n', mh_n_cases);

for mh_ci = 1:mh_n_cases
    mh_entry = mh_manifest(mh_ci);
    mh_id    = mh_entry.id;
    % vars from jsondecode: cell array for multi-element arrays, char for single string.
    % Normalize to a cell array of strings.
    mh_vars = mh_entry.vars;
    if ischar(mh_vars)
        mh_vars = {mh_vars};
    end
    % class_files is a cell array of filenames (may be empty).
    % jsondecode returns [] (0x0 double) for an empty JSON array, or a cell array
    % for a non-empty one. Normalize to a cell array either way.
    if isfield(mh_entry, 'class_files') && ~isempty(mh_entry.class_files)
        mh_class_files = mh_entry.class_files;
        if ~iscell(mh_class_files)
            mh_class_files = num2cell(mh_class_files);
        end
    else
        mh_class_files = {};
    end

    fprintf('  case %d/%d: %s\n', mh_ci, mh_n_cases, mh_id);

    % Run each case in its OWN function workspace so prior cases' variables
    % cannot bleed in. run_one_case returns the harvested struct (or a struct
    % with a run_error field on failure).
    mh_results.(mh_id) = run_one_case(mh_id, mh_vars, mh_class_files);
end

% Write matlab_results.json.
mh_out_text = jsonencode(mh_results);
mh_fid = fopen('matlab_results.json', 'w');
fprintf(mh_fid, '%s', mh_out_text);
fclose(mh_fid);
fprintf('oracle_harness: wrote matlab_results.json\n');
end


function mh_case_result = run_one_case(mh_id, mh_vars, mh_class_files)
% Execute one case in this function's (fresh) workspace and harvest its vars.
% Locals are mh_-prefixed so they cannot collide with a case's own variables
% (the case names are short/lowercase like s, v, f). Running the case script
% via run() creates the case's variables locally; they vanish when this
% function returns -- giving each case an isolated workspace.
mh_case_result = struct();
try
    % Write any class .m files to cwd so MATLAB finds them.
    for mh_fi = 1:numel(mh_class_files)
        mh_cf = mh_class_files{mh_fi};
        mh_cf_text = fileread(mh_cf);
        mh_fid = fopen(mh_cf, 'w');
        fprintf(mh_fid, '%s', mh_cf_text);
        fclose(mh_fid);
    end

    % Run the case script (already written to <id>.m by oracle_export.jl).
    run(mh_id);

    % Harvest each requested variable.
    for mh_vi = 1:numel(mh_vars)
        mh_vname = mh_vars{mh_vi};
        try
            mh_case_result.(mh_vname) = eval(mh_vname);
        catch mh_harvest_err
            mh_case_result.(mh_vname) = ['HARVEST_ERROR: ' mh_harvest_err.message];
        end
    end
catch mh_run_err
    mh_case_result.run_error = mh_run_err.message;
end
end
