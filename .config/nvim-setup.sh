#!/bin/sh
###########################################################################
# Required system-wide installs
###########################################################################
sudo apt-get install lua5.4 npm ripgrep universal-ctags
cargo install --locked tree-sitter-cli
sudo npm install -g vim-language-server

###########################################################################
# Get latest nvim if none installed
###########################################################################
if ! command -v nvim >/dev/null 2>&1; then
     wget https://github.com/neovim/neovim-releases/releases/latest/download/nvim-linux-x86_64.deb
     sudo apt install ./nvim-linux-x86_64.deb
     rm -v ./nvim-linux-x86_64.deb
fi

###########################################################################
# Set up nvim config (Edited version of https://github.com/jdhao/nvim-config)
###########################################################################
# Fall back to ${HOME}/.local/share if XDG_DATA_HOME undefined
pushd "${XDG_DATA_HOME:-${HOME}/.local/share}"
if [[ -d ./nvim ]]; then
    mv "./nvim" "./nvim_backup_$(date +%s)"
fi
popd
# Fall back to ${HOME}/.config if XDG_CONFIG_HOME undefined
pushd "${XDG_CONFIG_HOME:-${HOME}/.config}"
if [[ -d ./nvim ]]; then
    mv "./nvim" "./nvim_backup_$(date +%s)"
fi
mkdir nvim
cd nvim
git clone --depth=1 https://github.com/jdhao/nvim-config.git .
# Use custom plugin specs
cat <<'EOF' > lua/plugin_specs.lua
local utils = require("utils")

local plugin_dir = vim.fn.stdpath("data") .. "/lazy"
local lazypath = plugin_dir .. "/lazy.nvim"

if not vim.uv.fs_stat(lazypath) then
  vim.fn.system {
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- latest stable release
    lazypath,
  }
end
vim.opt.rtp:prepend(lazypath)

-- check if firenvim is active
local firenvim_not_active = function()
  return not vim.g.started_by_firenvim
end

local plugin_specs = {
  -- Mason (core package manager)
  {
    "williamboman/mason.nvim",
    cmd = "Mason",
    opts = {
      PATH = "prepend",           -- ← very important! Adds mason's bin/ to Neovim PATH
    },
  },
  -- Bridges mason -> lspconfig
  {
    "williamboman/mason-lspconfig.nvim",
    dependencies = { "williamboman/mason.nvim", "neovim/nvim-lspconfig" },
    opts = {
      ensure_installed = {
        "pyright",          -- installs delance-langserver under the hood
        "ruff",
        "yamlls",           -- yaml-language-server
        "bashls",           -- bash-language-server
      },

      -- Automatic setup for all installed servers (recommended!)
      automatic_installation = true,
      handlers = {
        function(server_name)
          require("lspconfig")[server_name].setup({})
        end,
      },
    },
  },
  -- auto-completion engine
  {
    "iguanacucumber/magazine.nvim",
    name = "nvim-cmp",
    -- event = 'InsertEnter',
    event = "VeryLazy",
    dependencies = {
      "hrsh7th/cmp-nvim-lsp",
      "onsails/lspkind-nvim",
      "hrsh7th/cmp-path",
      "hrsh7th/cmp-buffer",
      "hrsh7th/cmp-omni",
      "quangnguyen30192/cmp-nvim-ultisnips",
    },
    config = function()
      require("config.nvim-cmp")
    end,
  },
  {
    "neovim/nvim-lspconfig",
    event = { "BufRead", "BufNewFile" },
    config = function()
      require("config.lsp")
    end,
  },

  {
    "nvim-treesitter/nvim-treesitter",
    branch = "master",
    enabled = function()
      if vim.g.is_mac or vim.g.is_linux then
        return true
      end
      return false
    end,
    event = "VeryLazy",
    build = ":TSUpdate",
    config = function()
      require("config.treesitter")
    end,
  },

  -- Python-related text object
  { "jeetsukumaran/vim-pythonsense", ft = { "python" } },

  { "machakann/vim-swap", event = "VeryLazy" },

  -- IDE for Lisp
  -- 'kovisoft/slimv'
  {
    "vlime/vlime",
    enabled = function()
      if utils.executable("sbcl") then
        return true
      end
      return false
    end,
    config = function(plugin)
      vim.opt.rtp:append(plugin.dir .. "/vim")
    end,
    ft = { "lisp" },
  },

  -- Super fast buffer jump
  {
    "smoka7/hop.nvim",
    event = "VeryLazy",
    config = function()
      require("config.nvim_hop")
    end,
  },

  -- Show match number and index for searching
  {
    "kevinhwang91/nvim-hlslens",
    branch = "main",
    keys = { "*", "#", "n", "N" },
    config = function()
      require("config.hlslens")
    end,
  },
  {
    "Yggdroot/LeaderF",
    cmd = "Leaderf",
    build = function()
      local leaderf_path = plugin_dir .. "/LeaderF"
      vim.opt.runtimepath:append(leaderf_path)
      vim.cmd("runtime! plugin/leaderf.vim")

      if not vim.g.is_win then
        vim.cmd("LeaderfInstallCExtension")
      end
    end,
  },
  "nvim-lua/plenary.nvim",
  {
    "nvim-telescope/telescope.nvim",
    cmd = "Telescope",
    dependencies = {
      "nvim-telescope/telescope-symbols.nvim",
    },
  },
  {
    "ibhagwan/fzf-lua",
    -- optional for icon support
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      -- calling `setup` is optional for customization
      require("fzf-lua").setup {}
    end,
  },
  {
    "MeanderingProgrammer/markdown.nvim",
    main = "render-markdown",
    opts = {},
    dependencies = { "nvim-treesitter/nvim-treesitter", "nvim-tree/nvim-web-devicons" },
  },
  -- A list of colorscheme plugin you may want to try. Find what suits you.
  { "navarasu/onedark.nvim", lazy = true },
  { "sainnhe/edge", lazy = true },
  { "sainnhe/sonokai", lazy = true },
  { "sainnhe/gruvbox-material", lazy = true },
  { "sainnhe/everforest", lazy = true },
  { "EdenEast/nightfox.nvim", lazy = true },
  { "catppuccin/nvim", name = "catppuccin", lazy = true },
  { "olimorris/onedarkpro.nvim", lazy = true },
  { "marko-cerovac/material.nvim", lazy = true },
  {
    "rockyzhang24/arctic.nvim",
    dependencies = { "rktjmp/lush.nvim" },
    name = "arctic",
    branch = "v2",
  },
  { "rebelot/kanagawa.nvim", lazy = true },
  { "nvim-tree/nvim-web-devicons", event = "VeryLazy" },

  {
    "nvim-lualine/lualine.nvim",
    event = "VeryLazy",
    cond = firenvim_not_active,
    config = function()
      require("config.lualine")
    end,
  },

  {
    "akinsho/bufferline.nvim",
    event = { "BufEnter" },
    cond = firenvim_not_active,
    config = function()
      require("config.bufferline")
    end,
  },

  -- fancy start screen
  {
    "nvimdev/dashboard-nvim",
    cond = firenvim_not_active,
    config = function()
      require("config.dashboard-nvim")
    end,
  },
  {
    "luukvbaal/statuscol.nvim",
    opts = {},
    config = function()
      require("config.nvim-statuscol")
    end,
  },
  {
    "kevinhwang91/nvim-ufo",
    dependencies = "kevinhwang91/promise-async",
    event = "VeryLazy",
    opts = {},
    init = function()
      vim.o.foldcolumn = "1" -- '0' is not bad
      vim.o.foldlevel = 99 -- Using ufo provider need a large value, feel free to decrease the value
      vim.o.foldlevelstart = 99
      vim.o.foldenable = true
    end,
    config = function()
      require("config.nvim_ufo")
    end,
  },
  -- Highlight URLs inside vim
  { "itchyny/vim-highlighturl", event = "VeryLazy" },

  -- notification plugin
  {
    "rcarriga/nvim-notify",
    event = "VeryLazy",
    config = function()
      require("config.nvim-notify")
    end,
  },

  -- For Windows and Mac, we can open an URL in the browser. For Linux, it may
  -- not be possible since we maybe in a server which disables GUI.
  {
    "chrishrb/gx.nvim",
    keys = { { "gx", "<cmd>Browse<cr>", mode = { "n", "x" } } },
    cmd = { "Browse" },
    init = function()
      vim.g.netrw_nogx = 1 -- disable netrw gx
    end,
    enabled = function()
      if vim.g.is_win or vim.g.is_mac then
        return true
      else
        return false
      end
    end,
    dependencies = { "nvim-lua/plenary.nvim" },
    config = true, -- default settings
    submodules = false, -- not needed, submodules are required only for tests
  },

  -- Only install these plugins if ctags are installed on the system
  -- show file tags in vim window
  {
    "liuchengxu/vista.vim",
    enabled = function()
      if utils.executable("ctags") then
        return true
      else
        return false
      end
    end,
    cmd = "Vista",
  },

  -- Snippet engine and snippet template
  { "SirVer/ultisnips",
    dependencies = {
      "honza/vim-snippets",
    },
    event = "InsertEnter"
  },
  {
    "hrsh7th/nvim-cmp",
	  dependencies = {
	    "SirVer/ultisnips",                     -- required for UltiSnips itself
	    "quangnguyen30192/cmp-nvim-ultisnips",  -- cmp source for ultisnips
	  },

	  config = function()
	    local cmp = require("cmp")
	    local cmp_ultisnips = require("cmp_nvim_ultisnips")

	    -- Optional: setup some defaults (recommended)
	    cmp_ultisnips.setup({
	      -- filetype_source = "treesitter",     -- default anyway
	      -- show_snippets = "expandable",       -- or "all"
	    })

	    cmp.setup({
	      snippet = {
		expand = function(args)
		  vim.fn["UltiSnips#Anon"](args.body)  -- ← this is still the correct way
		end,
	      },

	      sources = cmp.config.sources({
		{ name = "nvim_lsp" },
		{ name = "ultisnips" },     -- important!
		{ name = "buffer" },
		{ name = "path" },
	      }),

	      -- Very recommended: better snippet/jump experience
	      mapping = cmp.mapping.preset.insert({
		["<Tab>"] = cmp.mapping(function(fallback)
		  if cmp.visible() then
		    cmp.select_next_item()
		  elseif cmp_ultisnips.can_expand_or_jump() then
		    cmp_ultisnips.expand_or_jump_forwards()
		  else
		    fallback()
		  end
		end, { "i", "s" }),

		["<S-Tab>"] = cmp.mapping(function(fallback)
		  if cmp.visible() then
		    cmp.select_prev_item()
		  elseif cmp_ultisnips.can_jump_backwards() then
		    cmp_ultisnips.jump_backwards()
		  else
		    fallback()
		  end
		end, { "i", "s" }),

		["<C-Space>"] = cmp.mapping.complete(),
		["<C-e>"]     = cmp.mapping.abort(),
		["<CR>"]      = cmp.mapping.confirm({ select = true }),
	      }),
	    })
	  end,
  },

  -- Automatic insertion and deletion of a pair of characters
  {
    "windwp/nvim-autopairs",
    event = "InsertEnter",
    config = true,
  },

  -- Comment plugin
  { "tpope/vim-commentary", event = "VeryLazy" },

  -- Multiple cursor plugin like Sublime Text?
  -- 'mg979/vim-visual-multi'

  -- Autosave files on certain events
  { "907th/vim-auto-save", event = "InsertEnter" },

  -- Show undo history visually
  { "simnalamburt/vim-mundo", cmd = { "MundoToggle", "MundoShow" } },

  -- better UI for some nvim actions
  { "stevearc/dressing.nvim" },

  -- Manage your yank history
  {
    "gbprod/yanky.nvim",
    config = function()
      require("config.yanky")
    end,
    event = "VeryLazy",
  },

  -- Handy unix command inside Vim (Rename, Move etc.)
  { "tpope/vim-eunuch", cmd = { "Rename", "Delete" } },

  -- Repeat vim motions
  { "tpope/vim-repeat", event = "VeryLazy" },

  { "nvim-zh/better-escape.vim", event = { "InsertEnter" } },

  -- Auto format tools
  { "sbdchd/neoformat", cmd = { "Neoformat" } },

  -- Git command inside vim
  {
    "tpope/vim-fugitive",
    event = "User InGitRepo",
    config = function()
      require("config.fugitive")
    end,
  },

  -- Better git log display
  { "rbong/vim-flog", cmd = { "Flog" } },
  { "akinsho/git-conflict.nvim", version = "*", config = true },
  {
    "ruifm/gitlinker.nvim",
    event = "User InGitRepo",
    config = function()
      require("config.git-linker")
    end,
  },

  -- Show git change (change, delete, add) signs in vim sign column
  {
    "lewis6991/gitsigns.nvim",
    config = function()
      require("config.gitsigns")
    end,
  },

  {
    "sindrets/diffview.nvim",
  },

  -- Another markdown plugin
  { "preservim/vim-markdown", ft = { "markdown" } },

  -- Faster footnote generation
  { "vim-pandoc/vim-markdownfootnotes", ft = { "markdown" } },

  -- Vim tabular plugin for manipulate tabular, required by markdown plugins
  { "godlygeek/tabular", cmd = { "Tabularize" } },

  {
    "rhysd/vim-grammarous",
    ft = { "markdown" },
  },

  { "chrisbra/unicode.vim", event = "VeryLazy" },

  -- Additional powerful text object for vim, this plugin should be studied
  -- carefully to use its full power
  { "wellle/targets.vim", event = "VeryLazy" },

  -- Plugin to manipulate character pairs quickly
  { "machakann/vim-sandwich", event = "VeryLazy" },

  -- Add indent object for vim (useful for languages like Python)
  { "michaeljsmith/vim-indent-object", event = "VeryLazy" },

  {
    "lervag/vimtex",
    enabled = function()
      if utils.executable("latex") then
        return true
      end
      return false
    end,
    ft = { "tex" },
  },

  -- Use knap for LaTeX live previewing
  {
    "frabjous/knap",
    enabled = function()
      if utils.executable("latex") then
        return true
      end
      return false
    end,
    ft = { "tex" },
  },

  {
    "tmux-plugins/vim-tmux",
    enabled = function()
      if utils.executable("tmux") then
        return true
      end
      return false
    end,
    ft = { "tmux" },
  },

  -- Modern matchit implementation
  { "andymass/vim-matchup", event = "BufRead" },
  { "tpope/vim-scriptease", cmd = { "Scriptnames", "Messages", "Verbose" } },

  -- Asynchronous command execution
  { "skywind3000/asyncrun.vim", lazy = true, cmd = { "AsyncRun" } },
  { "cespare/vim-toml", ft = { "toml" }, branch = "main" },

  -- Edit text area in browser using nvim
  {
    "glacambre/firenvim",
    enabled = function()
      local result = vim.g.is_win or vim.g.is_mac
      return result
    end,
    -- it seems that we can only call the firenvim function directly.
    -- Using vim.fn or vim.cmd to call this function will fail.
    build = function()
      local firenvim_path = plugin_dir .. "/firenvim"
      vim.opt.runtimepath:append(firenvim_path)
      vim.cmd("runtime! firenvim.vim")

      -- macOS will reset the PATH when firenvim starts a nvim process, causing the PATH variable to change unexpectedly.
      -- Here we are trying to get the correct PATH and use it for firenvim.
      -- See also https://github.com/glacambre/firenvim/blob/master/TROUBLESHOOTING.md#make-sure-firenvims-path-is-the-same-as-neovims
      local path_env = vim.env.PATH
      local prologue = string.format('export PATH="%s"', path_env)
      -- local prologue = "echo"
      local cmd_str = string.format(":call firenvim#install(0, '%s')", prologue)
      vim.cmd(cmd_str)
    end,
  },
  -- Debugger plugin
  {
    "sakhnik/nvim-gdb",
    enabled = function()
      if vim.g.is_win or vim.g.is_linux then
        return true
      end
      return false
    end,
    build = { "bash install.sh" },
    lazy = true,
  },

  -- Session management plugin
  { "tpope/vim-obsession", cmd = "Obsession" },

  {
    "ojroques/vim-oscyank",
    enabled = function()
      if vim.g.is_linux then
        return true
      end
      return false
    end,
    cmd = { "OSCYank", "OSCYankReg" },
  },

  -- The missing auto-completion for cmdline!
  {
    "gelguy/wilder.nvim",
    build = ":UpdateRemotePlugins",
  },

  -- showing keybindings
  {
    "folke/which-key.nvim",
    event = "VeryLazy",
    config = function()
      require("config.which-key")
    end,
  },

  -- show and trim trailing whitespaces
  { "jdhao/whitespace.nvim", event = "VeryLazy" },

  -- file explorer
  {
    "nvim-tree/nvim-tree.lua",
    event = "VeryLazy",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      require("config.nvim-tree")
    end,
  },

  {
    "j-hui/fidget.nvim",
    event = "VeryLazy",
    tag = "legacy",
    config = function()
      require("config.fidget-nvim")
    end,
  },
  {
    "folke/lazydev.nvim",
    ft = "lua", -- only load on lua files
    opts = {},
  },
  {
    "CopilotC-Nvim/CopilotChat.nvim",
    branch = "main",
    dependencies = {
      { "zbirenbaum/copilot.lua" }, -- or github/copilot.vim
      { "nvim-lua/plenary.nvim" , branch = "master" }, -- for curl, log and async functions
    },
    build = "make tiktoken", -- Only on MacOS or Linux
    opts = {
      debug = true, -- Enable debugging
      -- See Configuration section for rest
    },
    -- See Commands section for default commands if you want to lazy load on them
  },
  {
    "zbirenbaum/copilot.lua",
    cmd = "Copilot",
    config = function()
      require("copilot").setup {}
    end,
  },
  {
    "smjonas/live-command.nvim",
    -- live-command supports semantic versioning via Git tags
    -- tag = "2.*",
    cmd = "Preview",
    config = function()
      require("config.live-command")
    end,
    event = "VeryLazy",
  },
  {
    -- show hint for code actions, the user can also implement code actions themselves,
    -- see discussion here: https://github.com/neovim/neovim/issues/14869
    "kosayoda/nvim-lightbulb",
    config = function()
      require("nvim-lightbulb").setup { autocmd = { enabled = true } }
    end,
  },
  {
    "Bekaboo/dropbar.nvim",
  },
  {
    "vhyrro/luarocks.nvim",
    priority = 1000, -- Very high priority is required, luarocks.nvim should run as the first plugin in your config.
    opts = {
      rocks = { "lua-toml" }, -- specifies a list of rocks to install
      -- luarocks_build_args = { "--with-lua=/my/path" }, -- extra options to pass to luarocks's configuration script
    },
  },
}

require("lazy").setup {
  spec = plugin_specs,
  ui = {
    border = "rounded",
    title = "Plugin Manager",
    title_pos = "center",
  },
  rocks = {
    enabled = false,
    hererocks = false,
  },
}
EOF

###########################################################################
# Build with custom python env
###########################################################################
python -m venv venv
source venv/bin/activate

# Install required packages using pip
pip install --upgrade pip
pip install pynvim 'python-lsp-server[all]' pylsp-mypy python-lsp-isort python-lsp-black pylint flake8 vint pyright ruff

###########################################################################
# Add LaTeX live preview
###########################################################################
if command -v pdflatex &> /dev/null; then
    # Required software
    sudo apt install falkon pandoc sioyek latexmk rubber biber

    # Add preferred settings
    touch viml_conf/knap.vim
cat << EOF > ./viml_conf/knap.vim
""""""""""""""""""""""""""""knap/vimtex settings"""""""""""""""""""""""""""""
if executable('latex')
  " Set keybindings for knap per dev's recommendations
  """"""""""""""""""
  " KNAP functions "
  """"""""""""""""""
  " F5 processes the document once, and refreshes the view "
  inoremap <silent> <F5> <C-o>:lua require("knap").process_once()<CR>
  vnoremap <silent> <F5> <C-c>:lua require("knap").process_once()<CR>
  nnoremap <silent> <F5> :lua require("knap").process_once()<CR>

  " F6 closes the viewer application, and allows settings to be reset "
  inoremap <silent> <F6> <C-o>:lua require("knap").close_viewer()<CR>
  vnoremap <silent> <F6> <C-c>:lua require("knap").close_viewer()<CR>
  nnoremap <silent> <F6> :lua require("knap").close_viewer()<CR>

  " F7 toggles the auto-processing on and off "
  inoremap <silent> <F7> <C-o>:lua require("knap").toggle_autopreviewing()<CR>
  vnoremap <silent> <F7> <C-c>:lua require("knap").toggle_autopreviewing()<CR>
  nnoremap <silent> <F7> :lua require("knap").toggle_autopreviewing()<CR>

  " F8 invokes a SyncTeX forward search, or similar, where appropriate "
  inoremap <silent> <F8> <C-o>:lua require("knap").forward_jump()<CR>
  vnoremap <silent> <F8> <C-c>:lua require("knap").forward_jump()<CR>
  nnoremap <silent> <F8> :lua require("knap").forward_jump()<CR>

  let g:knap_settings = {
  \   "htmloutputext": "html",
  \   "htmltohtml": "none",
  \   "htmltohtmlviewerlaunch": "falkon %outputfile%",
  \   "htmltohtmlviewerrefresh": "none",
  \   "mdoutputext": "html",
  \   "mdtohtml": "pandoc --standalone %docroot% -o %outputfile%",
  \   "mdtohtmlviewerlaunch": "falkon %outputfile%",
  \   "mdtohtmlviewerrefresh": "none",
  \   "mdtopdf": "pandoc %docroot% -o %outputfile%",
  \   "mdtopdfviewerlaunch": "sioyek %outputfile%",
  \   "mdtopdfviewerrefresh": "none",
  \   "markdownoutputext": "html",
  \   "markdowntohtml": "pandoc --standalone %docroot% -o %outputfile%",
  \   "markdowntohtmlviewerlaunch": "falkon %outputfile%",
  \   "markdowntohtmlviewerrefresh": "none",
  \   "markdowntopdf": "pandoc %docroot% -o %outputfile%",
  \   "markdowntopdfviewerlaunch": "sioyek %outputfile%",
  \   "markdowntopdfviewerrefresh": "none",
  \   "texoutputext": "pdf",
  \   "textopdf": "pdflatex -interaction=batchmode -synctex=1 %docroot% || true",
  \   "textopdfviewerlaunch": "sioyek --inverse-search 'nvim --headless -es --cmd \"lua require('\"'\"'knaphelper'\"'\"').relayjump('\"'\"'%servername%'\"'\"','\"'\"'%1'\"'\"',%2,%3)\"' --new-window %outputfile%",
  \   "textopdfviewerrefresh": "none",
  \   "textopdfforwardjump": "sioyek --inverse-search 'nvim --headless -es --cmd \"lua require('\"'\"'knaphelper'\"'\"').relayjump('\"'\"'%servername%'\"'\"','\"'\"'%1'\"'\"',%2,%3)\"' --reuse-window --forward-search-file %srcfile% --forward-search-line %line% %outputfile%",
  \   "textopdfshorterror": "A=%outputfile% ; LOGFILE=\"${A%.pdf}.log\" ; rubber-info \"$LOGFILE\" 2>&1 | head -n 1",
  \   "delay": 250
  \ }
endif
EOF
fi

###########################################################################
# Add required extra config
###########################################################################
cat << EOF > viml_conf/plugins.vim

scriptencoding utf-8

" Plugin specification and lua stuff
lua require('plugin_specs')

" Use short names for common plugin manager commands to simplify typing.
" To use these shortcuts: first activate command line with :, then input the
" short alias, e.g., pi, then press <space>, the alias will be expanded to
" the full command automatically.
call utils#Cabbrev('pi', 'Lazy install')
call utils#Cabbrev('pud', 'Lazy update')
call utils#Cabbrev('pc', 'Lazy clean')
call utils#Cabbrev('ps', 'Lazy sync')

""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
"                      configurations for vim script plugin                  "
""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

"""""""""""""""""""""""""UltiSnips settings"""""""""""""""""""
" Trigger configuration. Do not use <tab> if you use YouCompleteMe
let g:UltiSnipsExpandTrigger='<c-j>'

" Do not look for SnipMate snippets
let g:UltiSnipsEnableSnipMate = 0

" Shortcut to jump forward and backward in tabstop positions
let g:UltiSnipsJumpForwardTrigger='<c-j>'
let g:UltiSnipsJumpBackwardTrigger='<c-k>'

" Configuration for custom snippets directory, see
" https://jdhao.github.io/2019/04/17/neovim_snippet_s1/ for details.
let g:UltiSnipsSnippetDirectories=['UltiSnips', 'my_snippets']

"""""""""""""""""""""""""" vlime settings """"""""""""""""""""""""""""""""
command! -nargs=0 StartVlime call jobstart(printf("sbcl --load %s/vlime/lisp/start-vlime.lisp", g:package_home))

"""""""""""""""""""""""""""""LeaderF settings"""""""""""""""""""""
" Do not use cache file
let g:Lf_UseCache = 0
" Refresh each time we call leaderf
let g:Lf_UseMemoryCache = 0

" Ignore certain files and directories when searching files
let g:Lf_WildIgnore = {
  \ 'dir': ['.git', '__pycache__', '.DS_Store', '*_cache'],
  \ 'file': ['*.exe', '*.dll', '*.so', '*.o', '*.pyc', '*.jpg', '*.png',
  \ '*.gif', '*.svg', '*.ico', '*.db', '*.tgz', '*.tar.gz', '*.gz',
  \ '*.zip', '*.bin', '*.pptx', '*.xlsx', '*.docx', '*.pdf', '*.tmp',
  \ '*.wmv', '*.mkv', '*.mp4', '*.rmvb', '*.ttf', '*.ttc', '*.otf',
  \ '*.mp3', '*.aac']
  \}

" Do not show fancy icons for Linux server.
if g:is_linux
  let g:Lf_ShowDevIcons = 0
endif

" Only fuzzy-search files names
let g:Lf_DefaultMode = 'FullPath'

" Do not use version control tool to list files under a directory since
" submodules are not searched by default.
let g:Lf_UseVersionControlTool = 0

" Use rg as the default search tool
let g:Lf_DefaultExternalTool = "rg"

" show dot files
let g:Lf_ShowHidden = 1

" Disable default mapping
let g:Lf_ShortcutF = ''
let g:Lf_ShortcutB = ''

" set up working directory for git repository
let g:Lf_WorkingDirectoryMode = 'a'

" Search files in popup window
nnoremap <silent> <leader>ff :<C-U>Leaderf file --popup<CR>

" Grep project files in popup window
nnoremap <silent> <leader>fg :<C-U>Leaderf rg --no-messages --popup  --nameOnly<CR>

" Search vim help files
nnoremap <silent> <leader>fh :<C-U>Leaderf help --popup<CR>

" Search tags in current buffer
nnoremap <silent> <leader>ft :<C-U>Leaderf bufTag --popup<CR>

" Switch buffers
nnoremap <silent> <leader>fb :<C-U>Leaderf buffer --popup<CR>

" Search recent files
nnoremap <silent> <leader>fr :<C-U>Leaderf mru --popup --absolute-path<CR>

let g:Lf_PopupColorscheme = 'gruvbox_material'

" Change keybinding in LeaderF prompt mode, use ctrl-n and ctrl-p to navigate
" items.
let g:Lf_CommandMap = {'<C-J>': ['<C-N>'], '<C-K>': ['<C-P>']}

" do not preview results, it will add the file to buffer list
let g:Lf_PreviewResult = {
      \ 'File': 0,
      \ 'Buffer': 0,
      \ 'Mru': 0,
      \ 'Tag': 0,
      \ 'BufTag': 1,
      \ 'Function': 1,
      \ 'Line': 0,
      \ 'Colorscheme': 0,
      \ 'Rg': 0,
      \ 'Gtags': 0
      \}

""""""""""""""""""""""""""" vista settings """"""""""""""""""""""""""""""""""
let g:vista#renderer#icons = {
      \ 'member': '',
      \ }

" Do not echo message on command line
let g:vista_echo_cursor = 0
" Stay in current window when vista window is opened
let g:vista_stay_on_open = 0

nnoremap <silent> <Space>t :<C-U>Vista!!<CR>

""""""""""""""""""""""""vim-mundo settings"""""""""""""""""""""""
let g:mundo_verbose_graph = 0
let g:mundo_width = 80

nnoremap <silent> <Space>u :MundoToggle<CR>

""""""""""""""""""""""""""""better-escape.vim settings"""""""""""""""""""""""""
let g:better_escape_interval = 200

""""""""""""""""""""""""""""vim-xkbswitch settings"""""""""""""""""""""""""
let g:XkbSwitchEnabled = 1

"""""""""""""""""""""""""""""" neoformat settings """""""""""""""""""""""
let g:neoformat_enabled_python = ['black', 'yapf']
let g:neoformat_cpp_clangformat = {
      \ 'exe': 'clang-format',
      \ 'args': ['--style="{IndentWidth: 4}"']
      \ }
let g:neoformat_c_clangformat = {
      \ 'exe': 'clang-format',
      \ 'args': ['--style="{IndentWidth: 4}"']
      \ }

let g:neoformat_enabled_cpp = ['clangformat']
let g:neoformat_enabled_c = ['clangformat']

"""""""""""""""""""""""""vim-markdown settings"""""""""""""""""""
" Disable header folding
let g:vim_markdown_folding_disabled = 1

" Whether to use conceal feature in markdown
let g:vim_markdown_conceal = 1

" Disable math tex conceal and syntax highlight
let g:tex_conceal = ''
let g:vim_markdown_math = 0

" Support front matter of various format
let g:vim_markdown_frontmatter = 1  " for YAML format
let g:vim_markdown_toml_frontmatter = 1  " for TOML format
let g:vim_markdown_json_frontmatter = 1  " for JSON format

" Let the TOC window autofit so that it doesn't take too much space
let g:vim_markdown_toc_autofit = 1

"""""""""""""""""""""""""markdown-preview settings"""""""""""""""""""
" Only setting this for suitable platforms
if g:is_win || g:is_mac
  " Do not close the preview tab when switching to other buffers
  let g:mkdp_auto_close = 0

  " Shortcuts to start and stop markdown previewing
  nnoremap <silent> <M-m> :<C-U>MarkdownPreview<CR>
  nnoremap <silent> <M-S-m> :<C-U>MarkdownPreviewStop<CR>
endif

""""""""""""""""""""""""vim-grammarous settings""""""""""""""""""""""""""""""
if g:is_mac
  let g:grammarous#languagetool_cmd = 'languagetool'
  let g:grammarous#disabled_rules = {
      \ '*' : ['WHITESPACE_RULE', 'EN_QUOTES', 'ARROWS', 'SENTENCE_WHITESPACE',
      \        'WORD_CONTAINS_UNDERSCORE', 'COMMA_PARENTHESIS_WHITESPACE',
      \        'EN_UNPAIRED_BRACKETS', 'UPPERCASE_SENTENCE_START',
      \        'ENGLISH_WORD_REPEAT_BEGINNING_RULE', 'DASH_RULE', 'PLUS_MINUS',
      \        'PUNCTUATION_PARAGRAPH_END', 'MULTIPLICATION_SIGN', 'PRP_CHECKOUT',
      \        'CAN_CHECKOUT', 'SOME_OF_THE', 'DOUBLE_PUNCTUATION', 'HELL',
      \        'CURRENCY', 'POSSESSIVE_APOSTROPHE', 'ENGLISH_WORD_REPEAT_RULE',
      \        'NON_STANDARD_WORD', 'AU', 'DATE_NEW_YEAR'],
      \ }

  augroup grammarous_map
    autocmd!
    autocmd FileType markdown nmap <buffer> <leader>x <Plug>(grammarous-close-info-window)
    autocmd FileType markdown nmap <buffer> <c-n> <Plug>(grammarous-move-to-next-error)
    autocmd FileType markdown nmap <buffer> <c-p> <Plug>(grammarous-move-to-previous-error)
  augroup END
endif

""""""""""""""""""""""""unicode.vim settings""""""""""""""""""""""""""""""
nmap ga <Plug>(UnicodeGA)

""""""""""""""""""""""""""""vim-sandwich settings"""""""""""""""""""""""""""""
" Map s to nop since s in used by vim-sandwich. Use cl instead of s.
nmap s <Nop>
omap s <Nop>

""""""""""""""""""""""""""""vimtex settings"""""""""""""""""""""""""""""
if executable('latex')
  " Hacks for inverse search to work semi-automatically,
  " see https://jdhao.github.io/2021/02/20/inverse_search_setup_neovim_vimtex/.
  function! s:write_server_name() abort
    let nvim_server_file = (has('win32') ? $TEMP : '/tmp') . '/vimtexserver.txt'
    call writefile([v:servername], nvim_server_file)
  endfunction

  augroup vimtex_common
    autocmd!
    autocmd FileType tex call s:write_server_name()
    autocmd FileType tex nmap <buffer> <F9> <plug>(vimtex-compile)
  augroup END

  let g:vimtex_compiler_latexmk = {
        \ 'build_dir' : 'build',
        \ }

  " TOC settings
  let g:vimtex_toc_config = {
        \ 'name' : 'TOC',
        \ 'layers' : ['content', 'todo', 'include'],
        \ 'resize' : 1,
        \ 'split_width' : 30,
        \ 'todo_sorted' : 0,
        \ 'show_help' : 1,
        \ 'show_numbers' : 1,
        \ 'mode' : 2,
        \ }

  " Viewer settings for different platforms
  if g:is_win
    let g:vimtex_view_general_viewer = 'SumatraPDF'
    let g:vimtex_view_general_options = '-reuse-instance -forward-search @tex @line @pdf'
  endif

  if g:is_mac
    " let g:vimtex_view_method = "skim"
    let g:vimtex_view_general_viewer = '/Applications/Skim.app/Contents/SharedSupport/displayline'
    let g:vimtex_view_general_options = '-r @line @pdf @tex'

    augroup vimtex_mac
      autocmd!
      autocmd User VimtexEventCompileSuccess call UpdateSkim()
    augroup END

    " The following code is adapted from https://gist.github.com/skulumani/7ea00478c63193a832a6d3f2e661a536.
    function! UpdateSkim() abort
      let l:out = b:vimtex.out()
      let l:src_file_path = expand('%:p')
      let l:cmd = [g:vimtex_view_general_viewer, '-r']

      if !empty(system('pgrep Skim'))
        call extend(l:cmd, ['-g'])
      endif

      call jobstart(l:cmd + [line('.'), l:out, l:src_file_path])
    endfunction
  endif
endif

""""""""""""""""""""""""""""vim-matchup settings"""""""""""""""""""""""""""""
" Improve performance
let g:matchup_matchparen_deferred = 1
let g:matchup_matchparen_timeout = 100
let g:matchup_matchparen_insert_timeout = 30

" Enhanced matching with matchup plugin
let g:matchup_override_vimtex = 1

" Whether to enable matching inside comment or string
let g:matchup_delim_noskips = 0

" Show offscreen match pair in popup window
let g:matchup_matchparen_offscreen = {'method': 'popup'}

"""""""""""""""""""""""""" asyncrun.vim settings """"""""""""""""""""""""""
" Automatically open quickfix window of 6 line tall after asyncrun starts
let g:asyncrun_open = 6
if g:is_win
  " Command output encoding for Windows
  let g:asyncrun_encs = 'gbk'
endif

""""""""""""""""""""""""""""""firenvim settings""""""""""""""""""""""""""""""
if exists('g:started_by_firenvim') && g:started_by_firenvim
  if g:is_mac
    set guifont=Iosevka\ Nerd\ Font:h18
  else
    set guifont=Consolas
  endif

  " general config for firenvim
  let g:firenvim_config = {
      \ 'globalSettings': {
          \ 'alt': 'all',
      \  },
      \ 'localSettings': {
          \ '.*': {
              \ 'cmdline': 'neovim',
              \ 'priority': 0,
              \ 'selector': 'textarea',
              \ 'takeover': 'never',
          \ },
      \ }
  \ }

  function s:setup_firenvim() abort
    set signcolumn=no
    set noruler
    set noshowcmd
    set laststatus=0
    set showtabline=0
  endfunction

  augroup firenvim
    autocmd!
    autocmd BufEnter * call s:setup_firenvim()
    autocmd BufEnter sqlzoo*.txt set filetype=sql
    autocmd BufEnter github.com_*.txt set filetype=markdown
    autocmd BufEnter stackoverflow.com_*.txt set filetype=markdown
  augroup END
endif

""""""""""""""""""""""""""""""nvim-gdb settings""""""""""""""""""""""""""""""
nnoremap <leader>dp :<C-U>GdbStartPDB python -m pdb %<CR>

""""""""""""""""""""""""""""""wilder.nvim settings""""""""""""""""""""""""""""""
call timer_start(250, { -> s:wilder_init() })

function! s:wilder_init() abort
  try
    call wilder#setup({
          \ 'modes': [':', '/', '?'],
          \ 'next_key': '<Tab>',
          \ 'previous_key': '<S-Tab>',
          \ 'accept_key': '<C-y>',
          \ 'reject_key': '<C-e>'
          \ })

    call wilder#set_option('pipeline', [
          \   wilder#branch(
          \     wilder#cmdline_pipeline({
          \       'language': 'python',
          \       'fuzzy': 1,
          \       'sorter': wilder#python_difflib_sorter(),
          \       'debounce': 30,
          \     }),
          \     wilder#python_search_pipeline({
          \       'pattern': wilder#python_fuzzy_pattern(),
          \       'sorter': wilder#python_difflib_sorter(),
          \       'engine': 're',
          \       'debounce': 30,
          \     }),
          \   ),
          \ ])

    let l:hl = wilder#make_hl('WilderAccent', 'Pmenu', [{}, {}, {'foreground': '#f4468f'}])
    call wilder#set_option('renderer', wilder#popupmenu_renderer({
          \ 'highlighter': wilder#basic_highlighter(),
          \ 'max_height': 15,
          \ 'highlights': {
          \   'accent': l:hl,
          \ },
          \ 'left': [' ', wilder#popupmenu_devicons(),],
          \ 'right': [' ', wilder#popupmenu_scrollbar(),],
          \ 'apply_incsearch_fix': 0,
          \ }))
  catch /^Vim\%((\a\+)\)\=:E117/
    echohl Error |echomsg "Wilder.nvim missing"| echohl None
  endtry
endfunction

""""""""""""""""""""""""""""""vim-auto-save settings""""""""""""""""""""""""""""""
let g:auto_save = 1  " enable AutoSave on Vim startup
EOF

cat << EOF > init.lua
-- This is my personal Nvim configuration supporting Mac, Linux and Windows, with various plugins configured.
-- This configuration evolves as I learn more about Nvim and become more proficient in using Nvim.
-- Since it is very long (more than 1000 lines!), you should read it carefully and take only the settings that suit you.
-- I would not recommend cloning this repo and replace your own config. Good configurations are personal,
-- built over time with a lot of polish.
--
-- Author: Jiedong Hao
-- Email: jdhao@hotmail.com
-- Blog: https://jdhao.github.io/
-- GitHub: https://github.com/jdhao
-- StackOverflow: https://stackoverflow.com/users/6064933/jdhao

-- Set the path to the Python interpreter in your venv (MUST BE AT START)
vim.env.VIRTUAL_ENV = vim.fn.expand('~/.config/nvim/venv/')
vim.g.python_host_prog = vim.fn.expand('~/.config/nvim/venv/bin/python')
vim.g.python3_host_prog = vim.fn.expand('~/.config/nvim/venv/bin/python3')
vim.env.PATH = vim.fn.expand('~/.config/nvim/venv/bin') .. ':' .. vim.env.PATH

vim.loader.enable()

local utils = require("utils")

local expected_version = "0.11.5"
utils.is_compatible_version(expected_version)

local config_dir = vim.fn.stdpath("config")
---@cast config_dir string

-- some global settings
require("globals")
-- setting options in nvim
vim.cmd("source " .. vim.fs.joinpath(config_dir, "viml_conf/options.vim"))
-- various autocommands
require("custom-autocmd")
-- all the user-defined mappings
require("mappings")
-- all the plugins installed and their configurations
vim.cmd("source " .. vim.fs.joinpath(config_dir, "viml_conf/plugins.vim"))
-- colorscheme settings
require("colorschemes")

--
-- ${USER}'s required additions
--

-- knap settings for latex live preview
vim.cmd("source ".. vim.fs.joinpath(config_dir, "viml_conf/knap.vim"))

require("nvim-tree").setup({
  update_focused_file = {
    enable = true,
    update_root = true
  },
})

EOF

###########################################################################
# Add QOL extras
###########################################################################
if [[ -f ${HOME}/.vimrc ]]; then
    cp -v ${HOME}/.vimrc ./viml_conf/${USER}_vimrc.vim
fi
# Some QOL changes for neovim
cat << EOF >> init.lua
--
-- ${USER}'s customization
--

-- User vimrc
--vim.cmd("source ".. vim.fs.joinpath(config_dir, "viml_conf/${USER}_vimrc.vim"))

-- knap settings for latex live preview
vim.cmd("source ".. vim.fs.joinpath(config_dir, "viml_conf/knap.vim"))

-- Space leader key
vim.g.mapleader = " "

-- Disable annoying color column
vim.opt.colorcolumn = ""
vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
  pattern = "*.py",
  callback = function()
    vim.opt_local.colorcolumn = ""
  end,
})

-- Set the terminal to use true colors
vim.opt.termguicolors = true
-- Decent colorscheme by default
vim.cmd("colorscheme default")
-- Function to set transparent background for all windows
function set_transparency()
  -- Set transparency for Normal and NonText
  vim.api.nvim_set_hl(0, "Normal", { bg = "NONE", ctermbg = "NONE" })
  vim.api.nvim_set_hl(0, "NonText", { bg = "NONE", ctermbg = "NONE" })

  -- Set transparency for other window types
  vim.api.nvim_set_hl(0, "NormalNC", { bg = "NONE", ctermbg = "NONE" })  -- Non-current windows
  vim.api.nvim_set_hl(0, "SignColumn", { bg = "NONE", ctermbg = "NONE" })  -- Sign column
  vim.api.nvim_set_hl(0, "StatusLine", { bg = "NONE", ctermbg = "NONE" })  -- Status line
  vim.api.nvim_set_hl(0, "StatusLineNC", { bg = "NONE", ctermbg = "NONE" })  -- Non-current status line
  vim.api.nvim_set_hl(0, "VertSplit", { bg = "NONE", ctermbg = "NONE" })  -- Vertical split line
  vim.api.nvim_set_hl(0, "Pmenu", { bg = "NONE", ctermbg = "NONE" })  -- Popup menu
  vim.api.nvim_set_hl(0, "PmenuSel", { bg = "#444444", fg = "#ffffff" })  -- Selected item in popup menu (optional)

  -- Transparency for floating windows (like help and command windows)
  vim.api.nvim_set_hl(0, "FloatBorder", { bg = "NONE", ctermbg = "NONE" })  -- Floating window border
  vim.api.nvim_set_hl(0, "NormalFloat", { bg = "NONE", ctermbg = "NONE" })  -- Normal in floating windows
end
-- Call the function initially
set_transparency()
-- Autocommand to reapply transparency when colorscheme changes
vim.cmd [[
    augroup Transparency
        autocmd!
        autocmd ColorScheme * lua set_transparency()
    augroup END
]]

-- Enable line wrapping
vim.opt.wrap = true               -- Enable line wrapping
vim.opt.linebreak = true          -- Break lines at word boundaries
vim.opt.textwidth = 0             -- Disable automatic line breaking on text width

-- Tab to switch buffers
vim.keymap.set('n', '<Tab>', ':bn<CR>', { noremap = true, silent = true })
vim.keymap.set('n', '<S-Tab>', ':bp<CR>', { noremap = true, silent = true })

-- Map <leader>q to delete the current buffer
vim.keymap.set('n', '<leader>q', ':bd<CR>', { noremap = true, silent = true })

-- Custom command, moves shifts first occurence of char to col
vim.api.nvim_create_user_command(
  'MoveToCol',
  function(opts)
    local char = opts.fargs[1]
    local col = tonumber(opts.fargs[2])
    if not char or not col then
      print("Usage: :MoveToCol <char> <column>")
      return
    end
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    for i, line in ipairs(lines) do
      local start, finish = string.find(line, vim.pesc(char))
      if start then
        -- Remove the character from its current position
        local newline = line:sub(1, start-1) .. line:sub(finish+1)
        -- Remove trailing spaces before inserting
        newline = newline:gsub("%s*$", "")
        -- Pad to (col-1) spaces, then insert the char, then rest of line
        local pad = string.rep(" ", math.max(col - #newline - 1, 0))
        newline = newline .. pad .. char
        -- If there was content after the char, append it
        if finish < #line then
          newline = newline .. line:sub(finish+1)
        end
        lines[i] = newline
      end
    end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  end,
  { nargs = "+" }
)

EOF

# Some QOL changes for neovim
cat << EOF >> plugin/command.lua
--
-- ${USER}'s customization
--


-- Custom command, shifts first occurence of char to col
-- TODO: Finish, supposed to exact implementation of this vim command (work on ranges + previewing):
-- :'<,'>:s/\(.*\)#\(.*\)/\=substitute(submatch(1), '\s*$', '', '') . repeat(' ', 55 - len(substitute(submatch(1), '\s*$', '', ''))) . '#' . submatch(2)/
vim.api.nvim_create_user_command('ShiftToCol', function(opts)
  local char = opts.fargs[1] or "#"
  local col = tonumber(opts.fargs[2]) or 55
  -- Get the current visual selection range
  local line1 = opts.line1
  local line2 = opts.line2
  -- Loop through the selected lines
  for lnum = line1, line2 do
    local line = vim.fn.getline(lnum)
    local before, after = line:match("^(.-)" .. vim.pesc(char) .. "(.*)$")
    if before and after then
      before = before:gsub("%s*$", "")
      local spaces = math.max(col - #before, 0)
      local new_line = before .. string.rep(" ", spaces) .. char .. after
      vim.fn.setline(lnum, new_line)
    end
  end
end, {
  nargs = "*",
  range = true,
  desc = "Aligns separator to column"
})
EOF

###########################################################################
# Build
###########################################################################
echo "Installing nvim plugins, please wait"
#nvim -c "autocmd User LazyInstall quitall"  -c "lua require('lazy').install()"

nvim --headless \
  -c "Lazy! sync" \
  -c "MasonInstall ruff pyright yaml-language-server bash-language-server" \
  -c "TSUpdateSync markdown markdown_inline" \
  -c "qa"

echo "Setup complete!"

###########################################################################
# Cleanup
###########################################################################
#deactivate
popd
