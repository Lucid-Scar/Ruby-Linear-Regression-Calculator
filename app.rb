require 'json'
require 'sinatra'
require 'csv'
require 'roo'
require 'fileutils'

set :bind, '0.0.0.0'
set :port, ENV.fetch('PORT', 4567)

NUMBER_PATTERN = /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)\z/
FileUtils.mkdir_p('uploads')
FileUtils.mkdir_p('public') 

# Safety nets
get('/upload')  { redirect '/' }
get('/process') { redirect '/' }
get('/manual')  { redirect '/' }

get '/' do
  @step = 1
  @points = []
  @metrics = nil
  @error = nil
  erb :index
end

# Upload File
post '/upload' do
  begin
    raise ArgumentError, 'Please select a file to upload.' unless params['dataset'] && params['dataset'][:tempfile]
    
    tempfile = params['dataset'][:tempfile]
    @filename = "#{Time.now.to_i}_#{params['dataset'][:filename]}"
    filepath = File.join('uploads', @filename)
    File.open(filepath, 'wb') { |f| f.write(tempfile.read) }

    raw_data = @filename.end_with?('.csv') ? CSV.read(filepath) : Roo::Spreadsheet.open(filepath).sheet(0).to_a
    raise ArgumentError, 'The uploaded file is empty.' if raw_data.empty?
    
    @headers = raw_data.first.map(&:to_s).map(&:strip)
    if @headers.compact.empty? || NUMBER_PATTERN.match?(@headers[0])
      raise ArgumentError, 'The dataset must contain text headers in the first row.'
    end

    @step = 2 
    @points = []
    erb :index
  rescue => e
    @error = e.message
    @step = 1
    @points = []
    erb :index
  end
end

# Process Simple Linear Regression from File
post '/process' do
  begin
    filepath = File.join('uploads', params['filename'])
    raise ArgumentError, 'File lost. Please upload again.' unless File.exist?(filepath)

    raw_data = params['filename'].end_with?('.csv') ? CSV.read(filepath) : Roo::Spreadsheet.open(filepath).sheet(0).to_a
    @headers = raw_data.first.map(&:to_s).map(&:strip)
    
    x_index = params['x_column'].to_i
    y_index = params['y_column'].to_i
    row_limit = params['row_limit'] # Can be 'all', '100', '500', '1000'

    raise ArgumentError, 'Please select two different variables.' if x_index == y_index

    # Assign Independent (X) and Dependent (Y) Variable Names from File or Custom Input
    custom_x = params['custom_x_name'].to_s.strip
    custom_y = params['custom_y_name'].to_s.strip

    @x_name = custom_x.empty? ? @headers[x_index] : custom_x
    @y_name = custom_y.empty? ? @headers[y_index] : custom_y
    @filename = params['filename'] 

    cleaned_data = []
    incomplete_rows = []

    raw_data[1..-1].each_with_index do |row, index|
      x_raw, y_raw = row[x_index], row[y_index]
      x_empty = x_raw.nil? || x_raw.to_s.strip.empty?
      y_empty = y_raw.nil? || y_raw.to_s.strip.empty?
      next if x_empty && y_empty

      incomplete_rows << index + 2 if x_empty || y_empty
      next if x_empty || y_empty

      if valid_number?(x_raw) && valid_number?(y_raw)
        # Store [ID, X, Y]
        cleaned_data << [index + 1, x_raw.to_f, y_raw.to_f]
      end
    end

    unless incomplete_rows.empty?
      rows = incomplete_rows.map(&:to_s).join(', ')
      raise ArgumentError, "Rows #{rows} must contain values for both selected variables."
    end

    raise ArgumentError, 'Not enough valid numeric data pairs found in those columns.' if cleaned_data.length < 2

    # Save full cleaned dataset
    timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
    @clean_filename = "Cleaned_Regression_Data_#{timestamp}.csv"
    
    CSV.open("public/#{@clean_filename}", "w") do |csv|
      csv << ['ID', @x_name, @y_name]
      cleaned_data.each { |row| csv << row }
    end

    # RANDOM UNIFORM SAMPLING
    processed_data = if row_limit == 'all' || row_limit.nil? || row_limit.to_i >= cleaned_data.length
                       cleaned_data
                     else
                       cleaned_data.sample(row_limit.to_i)
                     end

    # Structure points with IDs: [{ id: 1, x: val, y: val }]
    @points = processed_data.map { |item| { id: item[0], x: item[1], y: item[2] } }
    @metrics = calculate_regression(@points)
    
    @step = 3
    erb :index
  rescue => e
    @error = e.message
    @step = 1
    @points = []
    erb :index
  end
end

# Manual Entry
post '/manual' do
  begin
    x_values = parse_values(params['x_values'])
    y_values = parse_values(params['y_values'])
    
    raise ArgumentError, 'Enter at least two complete X/Y pairs.' if x_values.length < 2
    raise ArgumentError, 'X and Y must contain the same number of values.' unless x_values.length == y_values.length

    custom_x = params['custom_x_name'].to_s.strip
    custom_y = params['custom_y_name'].to_s.strip

    @x_name = custom_x.empty? ? "Independent Variable (X)" : custom_x
    @y_name = custom_y.empty? ? "Dependent Variable (Y)" : custom_y
    
    @points = x_values.each_with_index.map { |x, idx| { id: idx + 1, x: x, y: y_values[idx] } }
    @metrics = calculate_regression(@points)
    
    @step = 3
    erb :index
  rescue => e
    @error = e.message
    @step = 1
    @points = Array(params['x_values']).zip(Array(params['y_values'])).each_with_index.map { |p, idx| { id: idx + 1, x: p[0], y: p[1] } }
    erb :index
  end
end

def valid_number?(val)
  !val.nil? && NUMBER_PATTERN.match?(val.to_s.strip)
end

def parse_values(raw_values)
  values = Array(raw_values).map(&:to_s).map(&:strip)
  raise ArgumentError, 'Only integers or decimal numbers allowed.' if values.empty? || values.any? { |v| v.empty? || !NUMBER_PATTERN.match?(v) }
  values.map(&:to_f)
end

def calculate_regression(points)
  count = points.length
  x_mean = points.sum { |p| p[:x] } / count.to_f
  y_mean = points.sum { |p| p[:y] } / count.to_f

  table_data = points.map do |p|
    x_dev = p[:x] - x_mean
    y_dev = p[:y] - y_mean
    {
      id: p[:id],
      x: p[:x],
      y: p[:y],
      x_dev: x_dev,
      y_dev: y_dev,
      x_dev_y_dev: x_dev * y_dev,
      x_dev_sq: x_dev**2
    }
  end

  sum_x_deviation_squared = table_data.sum { |row| row[:x_dev_sq] }
  raise ArgumentError, 'The X values must not all be identical.' if sum_x_deviation_squared.zero?

  covariance = table_data.sum { |row| row[:x_dev_y_dev] }
  sum_y_deviation_squared = table_data.sum { |row| row[:y_dev]**2 }
  slope = covariance / sum_x_deviation_squared
  intercept = y_mean - slope * x_mean
  
  correlation = sum_y_deviation_squared.zero? ? 0.0 : covariance / Math.sqrt(sum_x_deviation_squared * sum_y_deviation_squared)
  sse = 0
  table_data.each do |row|
    row[:predicted_y] = intercept + slope * row[:x]
    sse += (row[:y] - row[:predicted_y])**2
  end

  {
    slope: slope,
    intercept: intercept,
    correlation: correlation,
    r_squared: correlation**2,
    sse: sse,
    table_data: table_data
  }
end

helpers do
  def format_number(value)
    format('%.6f', value).sub(/0+\z/, '').sub(/\.\z/, '')
  end

  def interpret_regression(metrics, point_count, x_name = 'X', y_name = 'Y')
    slope_direction = if metrics[:slope].positive?
                        'positive'
                      elsif metrics[:slope].negative?
                        'negative'
                      else
                        'no'
                      end
    slope_description = case slope_direction
                        when 'positive'
                          "As #{x_name} (Independent Variable) increases, #{y_name} (Dependent Variable) tends to increase."
                        when 'negative'
                          "As #{x_name} (Independent Variable) increases, #{y_name} (Dependent Variable) tends to decrease."
                        else
                          "Changes in #{x_name} are not associated with a linear change in #{y_name}."
                        end

    correlation_strength = case metrics[:correlation].abs
                           when 0.8.. then 'strong'
                           when 0.5...0.8 then 'moderate'
                           when 0.3...0.5 then 'weak'
                           else 'very weak'
                           end

    slope_change = slope_direction == 'no' ? "no average change in #{y_name} for each one-unit change in #{x_name}" : "#{slope_direction == 'positive' ? 'an increase' : 'a decrease'} of #{format_number(metrics[:slope].abs)} units in #{y_name} for each one-unit increase in #{x_name}"

    [
      "Independent Variable (X): <strong>#{x_name}</strong> | Dependent Variable (Y): <strong>#{y_name}</strong>.",
      "The fitted line predicts #{slope_change} (slope: #{format_number(metrics[:slope])}). #{slope_description}",
      "The correlation is #{correlation_strength} (r = #{format_number(metrics[:correlation])}), indicating the linear relationship strength between #{x_name} and #{y_name}.",
      "R-squared is #{format_number(metrics[:r_squared] * 100)}%, meaning the model accounts for approximately #{format_number(metrics[:r_squared] * 100)}% of the observed variance in #{y_name}.",
      "This model reflects a randomized sample of #{point_count} observations to avoid temporal sampling bias."
    ]
  end
end

__END__
@@index
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Neon Regression Lab</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
  <style>
    :root {
      --ink: #1c2733; --muted: #5d6b79; --steel: #1c6da8;
      --steel-light: #5ba7d8; --orange: #d66a2c;
      --panel: rgba(248, 250, 252, 0.94);
      --line: rgba(54, 75, 94, .25);
    }
    * { box-sizing: border-box; }
    body {
      color: var(--ink); background-color: #dfe5eb;
      background-image: linear-gradient(rgba(44, 67, 87, .11) 1px, transparent 1px),
        linear-gradient(90deg, rgba(44, 67, 87, .11) 1px, transparent 1px);
      background-size: 30px 30px; font-family: "Rajdhani", "Trebuchet MS", sans-serif;
      letter-spacing: .03em;
    }
    .panel {
      background: var(--panel); border: 1px solid rgba(255, 255, 255, .95);
      box-shadow: 0 12px 28px rgba(54, 75, 94, .16), inset 0 1px 0 #fff; border-radius: 4px;
    }
    .metal-title { color: #24394b; text-shadow: 0 2px 0 #fff, 0 0 18px rgba(91, 167, 216, .45); }
    .value { color: var(--steel); text-shadow: 0 1px 0 #fff; }
    .metal-button {
      background: linear-gradient(135deg, #277db4, #164d78); border: 1px solid #a9d8f2;
      box-shadow: 0 4px 12px rgba(28, 109, 168, .28), inset 0 1px 0 rgba(255,255,255,.55); color: #fff;
    }
    input, select { color: #1c4f73; background: #f7f9fb; border: 1px solid #aab8c5; outline: none; }
    input:focus, select:focus { border-color: var(--steel); box-shadow: 0 0 0 3px rgba(91, 167, 216, .22); }
    .metric { border-left: 3px solid var(--orange); }
    .muted { color: var(--muted); }
    .metal-heading { color: #29445b; }
    .metal-status { color: var(--orange); }
    .metal-outline { border-color: #6d9fbe; color: #1c6da8; }
    .metal-alert { border-color: #d66a2c; background: #fff1e9; color: #8a3f1d; box-shadow: 0 5px 15px rgba(214, 106, 44, .15); }
    .metal-alert strong { color: #b14e20; }
    
    .modal-overlay {
      position: fixed; top: 0; left: 0; width: 100%; height: 100%;
      background: rgba(28, 39, 51, 0.8); backdrop-filter: blur(4px);
      display: flex; justify-content: center; align-items: center; z-index: 50;
    }
  </style>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Rajdhani:wght@400;500;600;700&display=swap" rel="stylesheet">
</head>
<body class="min-h-screen relative">
  <main class="mx-auto max-w-6xl px-4 py-8 sm:px-8 sm:py-12">
    <header class="mb-8 border-b border-cyan-400/30 pb-6">
      <h1 class="metal-title text-3xl font-bold uppercase tracking-widest sm:text-5xl">Regression Lab</h1>
      <p class="muted mt-3 max-w-2xl text-sm">Automated Simple Linear Regression with contextual data preprocessing.</p>
    </header>

    <% if @error %>
      <div class="metal-alert mb-6 border p-4 text-sm" role="alert">
        <span class="font-bold">INPUT ERROR:</span> <%= @error %>
      </div>
    <% end %>

    <!-- STEP 2 MODAL POPUP -->
    <% if @step == 2 %>
      <div class="modal-overlay">
        <form class="panel w-full max-w-lg p-6 sm:p-8 m-4" method="post" action="/process">
          <div class="flex justify-between items-center mb-6 border-b border-slate-300 pb-4">
            <h2 class="metal-heading text-xl font-bold uppercase tracking-wider">Select Variables & Scope</h2>
            <a href="/" class="text-slate-400 hover:text-red-500 text-xl font-bold">&times;</a>
          </div>
          <input type="hidden" name="filename" value="<%= @filename %>">
          
          <div class="mb-5">
            <label class="mb-2 block text-sm font-bold uppercase tracking-wider text-slate-500">Independent Variable (X-Axis)</label>
            <select name="x_column" id="x_col_select" onchange="updateXPlaceholder()" class="w-full px-4 py-3 text-sm font-bold text-[#1c6da8]">
              <% @headers.each_with_index do |header, idx| %>
                <option value="<%= idx %>"><%= header %></option>
              <% end %>
            </select>
            <input type="text" name="custom_x_name" id="custom_x_input" placeholder="Display Label for X (Optional)" class="w-full mt-2 px-3 py-2 text-xs border rounded">
          </div>

          <div class="mb-5">
            <label class="mb-2 block text-sm font-bold uppercase tracking-wider text-slate-500">Dependent Variable (Y-Axis)</label>
            <select name="y_column" id="y_col_select" onchange="updateYPlaceholder()" class="w-full px-4 py-3 text-sm font-bold text-[#1c6da8]">
              <% @headers.each_with_index do |header, idx| %>
                <option value="<%= idx %>" <%= 'selected' if idx == 1 %>><%= header %></option>
              <% end %>
            </select>
            <input type="text" name="custom_y_name" id="custom_y_input" placeholder="Display Label for Y (Optional)" class="w-full mt-2 px-3 py-2 text-xs border rounded">
          </div>

          <div class="mb-8 border-t border-slate-300 pt-5">
            <label class="mb-2 block text-sm font-bold uppercase tracking-wider text-slate-500">Sample Limit (Random Sampling)</label>
            <select name="row_limit" class="w-full px-4 py-3 text-sm font-bold text-[#1c6da8]">
              <option value="all">Run All Cleaned Rows (Full Dataset)</option>
              <option value="100">Random 100 Sample Rows</option>
              <option value="500">Random 500 Sample Rows</option>
              <option value="1000">Random 1,000 Sample Rows</option>
            </select>
          </div>

          <button class="metal-button w-full rounded px-4 py-3 font-bold uppercase tracking-wider" type="submit">CLEAN & RUN MODEL</button>
        </form>
      </div>

      <script>
        function updateXPlaceholder() {
          const sel = document.getElementById('x_col_select');
          document.getElementById('custom_x_input').placeholder = `Display Label (Default: ${sel.options[sel.selectedIndex].text})`;
        }
        function updateYPlaceholder() {
          const sel = document.getElementById('y_col_select');
          document.getElementById('custom_y_input').placeholder = `Display Label (Default: ${sel.options[sel.selectedIndex].text})`;
        }
        updateXPlaceholder();
        updateYPlaceholder();
      </script>
    <% end %>

    <!-- EQUAL HEIGHT LAYOUT GRID -->
    <section class="grid gap-6 lg:grid-cols-[minmax(280px,380px)_1fr] items-stretch">
      
      <!-- LEFT PANEL: UPLOAD AND MANUAL ENTRY -->
      <div class="panel p-5 sm:p-6 flex flex-col justify-between h-full gap-6">
        
        <!-- FILE UPLOAD SECTOR -->
        <form method="post" action="/upload" enctype="multipart/form-data" onsubmit="return confirmNewGeneration(event)" class="border-b border-slate-300 pb-6">
          <div class="mb-4 flex items-center justify-between">
            <h2 class="metal-heading text-lg font-bold uppercase tracking-wider">File Upload</h2>
          </div>
          <input type="file" name="dataset" accept=".csv, .xls, .xlsx" required class="w-full text-[11px] text-slate-500 file:mr-2 file:rounded file:border-0 file:bg-[#1c6da8] file:px-2 file:py-1 file:text-[11px] file:font-bold file:text-white hover:file:bg-[#164d78]">
          <button class="metal-button w-full mt-3 rounded px-4 py-2 text-xs font-bold uppercase tracking-wider transition hover:brightness-110" type="submit">READ VARIABLES</button>
        </form>

        <!-- MANUAL ENTRY SECTOR -->
        <form method="post" action="/manual" id="regression-form" class="flex-1 flex flex-col justify-between">
          <div>
            <div class="mb-4 flex items-center justify-between">
              <h2 class="metal-heading text-lg font-bold uppercase tracking-wider">Data Stream</h2>
              <button class="text-xs text-slate-500 underline decoration-slate-400 underline-offset-4" type="button" onclick="window.location.href = '/';">CLEAR</button>
            </div>

            <div class="grid grid-cols-2 gap-2 mb-3">
              <input type="text" name="custom_x_name" placeholder="X Variable Name (IV)" class="px-2 py-1 text-xs border rounded font-bold text-[#1c6da8]">
              <input type="text" name="custom_y_name" placeholder="Y Variable Name (DV)" class="px-2 py-1 text-xs border rounded font-bold text-[#1c6da8]">
            </div>
            
            <div class="grid grid-cols-[40px_1fr_1fr_36px] gap-2 mb-3 text-xs uppercase tracking-wider muted font-bold text-center">
              <span>ID</span><span>X Input</span><span>Y Input</span><span aria-hidden="true"></span>
            </div>
            <div class="space-y-2 max-h-[260px] overflow-y-auto pr-1" id="manual-rows"></div>
          </div>
          
          <div>
            <div class="mt-5 flex flex-wrap gap-2">
              <button class="metal-outline border px-3 py-2 text-[10px] font-bold uppercase tracking-wider transition hover:bg-sky-50" type="button" onclick="addRow()">+ ADD ROW</button>
              <button class="metal-button flex-1 px-4 py-2 text-[10px] font-bold uppercase tracking-wider transition hover:brightness-110" type="submit">RUN MODEL</button>
            </div>
            <p class="muted mt-3 text-[11px] leading-relaxed">Accepted format: integers and decimals only.</p>
          </div>
        </form>
      </div>

      <script>
        const initialPoints = <%= @points.to_json %> || [];
        const isStep3 = <%= @step == 3 ? 'true' : 'false' %>;
        const rowContainer = document.getElementById('manual-rows');

        function confirmNewGeneration(event) {
          if (isStep3) {
            return confirm("A model output is currently active. Uploading a new file will reset the current session. Do you want to proceed?");
          }
          return true;
        }
        
        function addRow(xVal = '', yVal = '') {
          const rowIdx = rowContainer.children.length + 1;
          const row = document.createElement('div');
          row.className = 'grid grid-cols-[40px_1fr_1fr_36px] gap-2 items-center manual-row';
          row.innerHTML = `
            <span class="text-xs font-bold text-slate-400 text-center">#${rowIdx}</span>
            <input class="min-w-0 px-2 py-1.5 text-xs focus:border-[#1c6da8]" name="x_values[]" type="number" step="any" value="${xVal}" required>
            <input class="min-w-0 px-2 py-1.5 text-xs focus:border-[#1c6da8]" name="y_values[]" type="number" step="any" value="${yVal}" required>
            <button class="border border-slate-400 text-base text-slate-500 hover:bg-slate-100 flex items-center justify-center h-full rounded" type="button">&times;</button>
          `;
          row.querySelector('button').onclick = () => { 
            if (rowContainer.children.length > 2) {
              row.remove();
              updateRowIDs();
            }
          };
          rowContainer.appendChild(row);
        }

        function updateRowIDs() {
          Array.from(rowContainer.children).forEach((row, i) => {
            row.querySelector('span').innerText = `#${i + 1}`;
          });
        }

        function renderInitial() {
          rowContainer.innerHTML = '';
          if (initialPoints.length > 0) {
            initialPoints.forEach(p => addRow(p.x !== undefined ? p.x : '', p.y !== undefined ? p.y : ''));
          } else {
            addRow(); addRow();
          }
        }
        renderInitial();
      </script>

      <!-- RIGHT PANEL: MODEL OUTPUT -->
      <div class="h-full flex flex-col">
        <% if @step == 3 && @filename && @headers %>
          <div class="panel p-3 mb-4 flex items-center gap-3">
            <button class="metal-button rounded px-4 py-1 text-[10px] font-bold uppercase tracking-wider" onclick="document.getElementById('vars-modal').style.display='flex'">CHANGE VARIABLES / LABELS</button>
            <% if @clean_filename %>
              <a href="/<%= @clean_filename %>" download class="metal-outline border rounded px-4 py-1 text-[10px] font-bold uppercase transition hover:bg-sky-50 ml-auto">DOWNLOAD CLEAN CSV</a>
            <% end %>
          </div>

          <!-- Hidden Change Variables Modal -->
          <div id="vars-modal" class="modal-overlay" style="display:none;">
            <form class="panel w-full max-w-lg p-6 sm:p-8 m-4" method="post" action="/process">
              <div class="flex justify-between items-center mb-6 border-b border-slate-300 pb-4">
                <h2 class="metal-heading text-xl font-bold uppercase tracking-wider">Change Variables & Labels</h2>
                <button type="button" onclick="document.getElementById('vars-modal').style.display='none'" class="text-slate-400 hover:text-red-500 text-xl font-bold">&times;</button>
              </div>
              <input type="hidden" name="filename" value="<%= @filename %>">
              
              <div class="mb-5">
                <label class="mb-2 block text-sm font-bold uppercase tracking-wider text-slate-500">Independent Variable (X-Axis)</label>
                <select name="x_column" class="w-full px-4 py-3 text-sm font-bold text-[#1c6da8]">
                  <% @headers.each_with_index do |header, idx| %>
                    <option value="<%= idx %>" <%= 'selected' if header == @x_name %>><%= header %></option>
                  <% end %>
                </select>
                <input type="text" name="custom_x_name" value="<%= @x_name %>" placeholder="Custom Display Label for X" class="w-full mt-2 px-3 py-2 text-xs border rounded">
              </div>

              <div class="mb-5">
                <label class="mb-2 block text-sm font-bold uppercase tracking-wider text-slate-500">Dependent Variable (Y-Axis)</label>
                <select name="y_column" class="w-full px-4 py-3 text-sm font-bold text-[#1c6da8]">
                  <% @headers.each_with_index do |header, idx| %>
                    <option value="<%= idx %>" <%= 'selected' if header == @y_name %>><%= header %></option>
                  <% end %>
                </select>
                <input type="text" name="custom_y_name" value="<%= @y_name %>" placeholder="Custom Display Label for Y" class="w-full mt-2 px-3 py-2 text-xs border rounded">
              </div>

              <div class="mb-8 border-t border-slate-300 pt-5">
                <label class="mb-2 block text-sm font-bold uppercase tracking-wider text-slate-500">Sample Limit (Random Sampling)</label>
                <select name="row_limit" class="w-full px-4 py-3 text-sm font-bold text-[#1c6da8]">
                  <option value="all">Run All Cleaned Rows (Full Dataset)</option>
                  <option value="100">Random 100 Sample Rows</option>
                  <option value="500">Random 500 Sample Rows</option>
                  <option value="1000">Random 1,000 Sample Rows</option>
                </select>
              </div>

              <button class="metal-button w-full rounded px-4 py-3 font-bold uppercase tracking-wider" type="submit">UPDATE MODEL</button>
            </form>
          </div>
        <% end %>

        <section class="panel h-full flex flex-col justify-between p-5 sm:p-6">
          <div class="mb-4 flex items-center justify-between">
            <h2 class="metal-heading text-lg font-bold uppercase tracking-wider">Model Output</h2>
            <span class="metal-status text-xs"><%= @metrics ? 'STATUS: COMPLETE' : 'STATUS: AWAITING DATA' %></span>
          </div>
          <div class="relative h-[320px] sm:h-[380px] w-full"><canvas id="regression-chart"></canvas></div>
        </section>
      </div>
    </section>

    <% if @metrics %>
      <section class="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <div class="panel metric p-4"><p class="muted text-[10px] tracking-wider font-bold">SLOPE / B1</p><p class="value mt-2 text-xl font-bold"><%= format_number(@metrics[:slope]) %></p></div>
        <div class="panel metric p-4"><p class="muted text-[10px] tracking-wider font-bold">INTERCEPT / B0</p><p class="value mt-2 text-xl font-bold"><%= format_number(@metrics[:intercept]) %></p></div>
        <div class="panel metric p-4"><p class="muted text-[10px] tracking-wider font-bold">CORRELATION / R</p><p class="value mt-2 text-xl font-bold"><%= format_number(@metrics[:correlation]) %></p></div>
        <div class="panel metric p-4"><p class="muted text-[10px] tracking-wider font-bold">R-SQUARED</p><p class="value mt-2 text-xl font-bold"><%= format_number(@metrics[:r_squared]) %></p></div>
        <div class="panel metric p-4"><p class="muted text-[10px] tracking-wider font-bold">SSE (ERROR)</p><p class="value mt-2 text-xl font-bold"><%= format_number(@metrics[:sse]) %></p></div>
      </section>
      
      <p class="mt-5 text-center text-sm text-slate-600 font-bold">
        <%= @y_name %> = <%= format_number(@metrics[:slope]) %> &bull; (<%= @x_name %>) <%= @metrics[:intercept] >= 0 ? '+' : '-' %> <%= format_number(@metrics[:intercept].abs) %>
      </p>

      <!-- STEP-BY-STEP CALCULATION TABLE FROM APP_2.RB -->
      <section class="panel mt-6 p-5 sm:p-6 overflow-x-auto">
        <h2 class="metal-heading text-lg font-bold uppercase tracking-wider mb-4">Calculation Table</h2>
        <table class="w-full text-sm text-center text-slate-600 border-collapse border border-slate-300">
          <thead class="bg-slate-100 text-[#1c6da8] font-bold text-[12px] tracking-wider border-b border-slate-300">
            <tr>
              <th class="p-3 border-r border-slate-300">ID</th>
              <th class="p-3 border-r border-slate-300">X (<%= @x_name %>)</th>
              <th class="p-3 border-r border-slate-300">Y (<%= @y_name %>)</th>
              <th class="p-3 border-r border-slate-300">X - X̄</th>
              <th class="p-3 border-r border-slate-300">Y - Ȳ</th>
              <th class="p-3 border-r border-slate-300">(X - X̄)(Y - Ȳ)</th>
              <th class="p-3 border-r border-slate-300">(X - X̄)²</th>
              <th class="p-3">Predicted Y (Ŷ)</th>
            </tr>
          </thead>
          <tbody>
            <% @metrics[:table_data].each do |row| %>
              <tr class="border-b border-slate-200 hover:bg-sky-50 transition">
                <td class="p-2 border-r border-slate-200 font-bold">#<%= row[:id] %></td>
                <td class="p-2 border-r border-slate-200"><%= format_number(row[:x]) %></td>
                <td class="p-2 border-r border-slate-200"><%= format_number(row[:y]) %></td>
                <td class="p-2 border-r border-slate-200"><%= format_number(row[:x_dev]) %></td>
                <td class="p-2 border-r border-slate-200"><%= format_number(row[:y_dev]) %></td>
                <td class="p-2 border-r border-slate-200"><%= format_number(row[:x_dev_y_dev]) %></td>
                <td class="p-2 border-r border-slate-200"><%= format_number(row[:x_dev_sq]) %></td>
                <td class="p-2"><%= format_number(row[:predicted_y]) %></td>
              </tr>
            <% end %>
            <tr class="bg-slate-200 font-bold text-slate-700 text-[13px]">
              <td class="p-3 border-r border-slate-300">Total</td>
              <td class="p-3 border-r border-slate-300">Σ = <%= format_number(@points.sum { |p| p[:x] }) %></td>
              <td class="p-3 border-r border-slate-300">Σ = <%= format_number(@points.sum { |p| p[:y] }) %></td>
              <td class="p-3 border-r border-slate-300">Σ = 0</td>
              <td class="p-3 border-r border-slate-300">Σ = 0</td>
              <td class="p-3 border-r border-slate-300">Σ = <%= format_number(@metrics[:table_data].sum { |row| row[:x_dev_y_dev] }) %></td>
              <td class="p-3 border-r border-slate-300">Σ = <%= format_number(@metrics[:table_data].sum { |row| row[:x_dev_sq] }) %></td>
              <td class="p-3">Σ = <%= format_number(@metrics[:table_data].sum { |row| row[:predicted_y] }) %></td>
            </tr>
          </tbody>
        </table>
      </section>

      <section class="panel mt-6 p-5 sm:p-6">
        <h2 class="metal-heading text-lg font-bold uppercase tracking-wider">Interpretation of Results</h2>
        <ul class="mt-4 list-disc space-y-2 pl-5 text-sm leading-relaxed text-slate-600">
          <% interpret_regression(@metrics, @points.length, @x_name, @y_name).each do |interpretation| %>
            <li><%= interpretation %></li>
          <% end %>
        </ul>
      </section>

      <script>
        const metricPoints = <%= @points.to_json %>.map(p => ({ id: p.id, x: p.x, y: p.y }));
        const minX = Math.min(...metricPoints.map(p => p.x));
        const maxX = Math.max(...metricPoints.map(p => p.x));
        const slope = <%= @metrics[:slope] %>;
        const intercept = <%= @metrics[:intercept] %>;
        
        new Chart(document.getElementById('regression-chart'), {
          type: 'scatter',
          data: { datasets: [
            { label: 'Observed Data', data: metricPoints, backgroundColor: '#277db4', borderColor: '#164d78', pointRadius: 5 },
            { label: 'Line of Best Fit', data: [{x: minX, y: intercept + slope * minX}, {x: maxX, y: intercept + slope * maxX}], type: 'line', borderColor: '#d66a2c', borderWidth: 2, pointRadius: 0, tension: 0 }
          ]},
          options: { responsive: true, maintainAspectRatio: false, scales: {
            x: { type: 'linear', title: {display: true, text: "<%= @x_name %> (Independent Variable)"}, grid: { color: 'rgba(54,75,94,.14)' }, ticks: { color: '#5d6b79' } },
            y: { title: {display: true, text: "<%= @y_name %> (Dependent Variable)"}, grid: { color: 'rgba(54,75,94,.14)' }, ticks: { color: '#5d6b79' } }
          }, plugins: { 
            legend: { labels: { color: '#1c2733', font: { family: 'Rajdhani' } } },
            tooltip: {
              callbacks: {
                label: function(context) {
                  if (context.dataset.type === 'line') return 'Line of Best Fit';
                  const p = context.raw;
                  return `Point ID #${p.id}: X = ${p.x}, Y = ${p.y}`;
                }
              }
            }
          }}
        });
      </script>
    <% end %>
  </main>
</body>
</html>