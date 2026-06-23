% oracle_harness.m — MATLAB oracle harness for Mjolnir CI.
%
% Reads manifest.json from the current working directory, executes each case
% in a try/catch (so one failure records an error marker instead of aborting),
% harvests the requested variables via jsonencode, and writes matlab_results.json.
%
% Usage (from matlab-actions/run-command):
%   cd('<workdir>'); oracle_harness
%
% Output format (matlab_results.json):
%   { "<id>": { "<var>": <json_value>, ... }, ... }
% On per-case failure:
%   { "<id>": { "__error__": "<message>" }, ... }

fprintf('oracle_harness: reading manifest.json\n');
manifest_text = fileread('manifest.json');
manifest = jsondecode(manifest_text);

results = struct();

n_cases = numel(manifest);
fprintf('oracle_harness: %d cases to run\n', n_cases);

for ci = 1:n_cases
    entry = manifest(ci);
    id    = entry.id;
    vars  = entry.vars;
    % class_files is a cell array of filenames (may be empty)
    if isfield(entry, 'class_files')
        class_files = entry.class_files;
    else
        class_files = {};
    end

    fprintf('  case %d/%d: %s\n', ci, n_cases, id);

    case_result = struct();
    try
        % Write any class .m files to cwd so MATLAB finds them.
        for fi = 1:numel(class_files)
            cf = class_files{fi};
            cf_text = fileread(cf);
            fid = fopen(cf, 'w');
            fprintf(fid, '%s', cf_text);
            fclose(fid);
        end

        % Run the case script (already written to <id>.m by oracle_export.jl).
        run(id);

        % Harvest each requested variable.
        for vi = 1:numel(vars)
            vname = vars{vi};
            try
                val = eval(vname);
                case_result.(vname) = val;
            catch harvest_err
                case_result.(vname) = struct('__harvest_error__', harvest_err.message);
            end
        end
    catch run_err
        case_result.__error__ = run_err.message;
    end

    results.(id) = case_result;
end

% Write matlab_results.json.
out_text = jsonencode(results);
fid = fopen('matlab_results.json', 'w');
fprintf(fid, '%s', out_text);
fclose(fid);
fprintf('oracle_harness: wrote matlab_results.json\n');
