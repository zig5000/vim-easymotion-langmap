let s:save_cpo = &cpo
set cpo&vim

" Use a Funcref as a special term _UNDEFINED
function! s:undefined() abort
  return 'undefined'
endfunction
let s:_UNDEFINED = function('s:undefined')

function! s:_vital_loaded(V) abort
  let s:V = a:V
  let s:Prelude = s:V.import('Prelude')
  let s:List = s:V.import('Data.List')
  let s:Dict = s:V.import('Data.Dict')
endfunction
function! s:_vital_depends() abort
  return ['Prelude', 'Data.List', 'Data.Dict']
endfunction
function! s:_vital_created(module) abort
  " define constant variables
  if !exists('s:const')
    let s:const = {}
    let s:const.is_local_variable_supported =
        \ v:version > 703 || (v:version == 703 && has('patch560'))
    " NOTE:
    " The third argument is available from 7.4.242 but it had bug and that
    " bug was fixed from 7.4.513
    let s:const.is_third_argument_of_getreg_supported = has('patch-7.4.513')
    lockvar s:const
  endif
  call extend(a:module, s:const)
endfunction
function! s:_throw(msg) abort
  throw printf('vital: Vim.Guard: %s', a:msg)
endfunction

let s:option = {}
function! s:_new_option(name) abort
  if a:name !~# '^&'
    call s:_throw(printf(
          \'An option name "%s" requires to be started from "&"', a:name
          \))
  elseif !exists(a:name)
    call s:_throw(printf(
          \'An option name "%s" does not exist', a:name
          \))
  endif
  let option = copy(s:option)
  let option.name = a:name
  let option.value = eval(a:name)
  return option
endfunction
function! s:option.restore() abort
  execute printf('let %s = %s', self.name, string(self.value))
endfunction

let s:register = {}
function! s:_new_register(name) abort
  if len(a:name) != 2
    call s:_throw(printf(
          \'A register name "%s" requires to be "@" + a single character', a:name
          \))
  elseif a:name !~# '^@'
    call s:_throw(printf(
          \'A register name "%s" requires to be started from "@"', a:name
          \))
  elseif a:name =~# '^@[:.%]$'
    call s:_throw(printf(
          \'A register name "%s" is read only', a:name
          \))
  elseif a:name !~# '^@[@0-9a-zA-Z#=*+~_/-]$'
    call s:_throw(printf(
          \'A register name "%s" does not exist. See ":help let-register"', a:name
          \))
  endif
  let name = a:name ==# '@@' ? '' : a:name[1]
  let register = copy(s:register)
  let register.name = name
  if s:const.is_third_argument_of_getreg_supported
    let register.value = getreg(name, 1, 1)
  else
    let register.value = getreg(name, 1)
  endif
  let register.type = getregtype(name)
  return register
endfunction
function! s:register.restore() abort
  call setreg(self.name, self.value, self.type)
endfunction

let s:environment = {}
function! s:_new_environment(name) abort
  if a:name !~# '^\$'
    call s:_throw(printf(
          \'An environment variable name "%s" requires to be started from "$"', a:name
          \))
  elseif !exists(a:name)
    call s:_throw(printf(
          \'An environment variable name "%s" does not exist. While Vim cannot unlet environment variable, it requires to exist', a:name
          \))
  endif
  let environment = copy(s:environment)
  let environment.name = a:name
  let environment.value = eval(a:name)
  return environment
endfunction
function! s:environment.restore() abort
  execute printf('let %s = %s', self.name, string(self.value))
endfunction

let s:variable = {}
function! s:_new_variable(name, ...) abort
  if a:0 == 0
    let m = matchlist(a:name, '^\([bwtg]:\)\(.*\)$')
    if empty(m)
      call s:_throw(printf(
            \ join([
            \   'An variable name "%s" requires to start from b:, w:, t:, or g:',
            \   'while no {namespace} is specified',
            \ ]),
            \ a:name,
            \))
    endif
    let [prefix, name] = m[1 : 2]
    let namespace = eval(prefix)
  else
    let name = a:name
    let namespace = a:1
  endif
  let variable = copy(s:variable)
  let variable.name = name
  let variable.value = get(namespace, name, s:_UNDEFINED)
  let variable.value =
        \ type(variable.value) == type({}) || type(variable.value) == type([])
        \   ? deepcopy(variable.value)
        \   : variable.value
  let variable._namespace = namespace
  return variable
endfunction
function! s:variable.restore() abort
  " unlet the variable to prevent variable type mis-match in case
  silent! unlet! self._namespace[self.name]
  if type(self.value) == type(s:_UNDEFINED) && self.value == s:_UNDEFINED
    " do nothing, leave the variable as undefined
  else
    let self._namespace[self.name] = self.value
  endif
endfunction

let s:instance = {}
function! s:_new_instance(instance, ...) abort
  let shallow = get(a:000, 0, 0)
  if !s:Prelude.is_list(a:instance) && !s:Prelude.is_dict(a:instance)
    call s:_throw(printf(
          \'An instance "%s" requires to be List or Dictionary', string(a:instance)
          \))
  endif
  let instance = copy(s:instance)
  let instance.instance = a:instance
  let instance.values = shallow ? copy(a:instance) : deepcopy(a:instance)
  return instance
endfunction
function! s:instance.restore() abort
  if s:Prelude.is_list(self.instance)
    call s:List.clear(self.instance)
  else
    call s:Dict.clear(self.instance)
  endif
  call extend(self.instance, self.values)
endfunction

let s:guard = {}
function! s:store(...) abort
  let resources = []
  for meta in a:000
    if s:Prelude.is_list(meta)
      if len(meta) == 1
        call add(resources, s:_new_instance(meta[0]))
      elseif len(meta) == 2
        if s:Prelude.is_string(meta[0])
          call add(resources, call('s:_new_variable', meta))
        else
          call add(resources, call('s:_new_instance', meta))
        endif
      else
        call s:_throw('List assignment requires one or two elements')
      endif
    elseif type(meta) == type('')
      if meta =~# '^[bwtgls]:'
        " Note:
        " To improve an error message, handle l:XXX or s:XXX as well
        call add(resources, s:_new_variable(meta))
      elseif meta =~# '^&'
        call add(resources, s:_new_option(meta))
      elseif meta =~# '^@'
        call add(resources, s:_new_register(meta))
      elseif meta =~# '^\$'
        call add(resources, s:_new_environment(meta))
      else
        call s:_throw(printf(
              \ 'Unknown value "%s" was specified',
              \ meta
              \))
      endif
    endif
    unlet meta
  endfor
  let guard = copy(s:guard)
  let guard._resources = resources
  return guard
endfunction
function! s:guard.restore() abort
  for resource in self._resources
    call resource.restore()
  endfor
endfunction

let &cpo = s:save_cpo
unlet! s:save_cpo
" vim:set et ts=2 sts=2 sw=2 tw=0 fdm=marker:
" ___Revitalizer___
" NOTE: below code is generated by :Revitalize.
" Do not mofidify the code nor append new lines
if v:version > 703 || v:version == 703 && has('patch1170')
  function! s:___revitalizer_function___(fstr) abort
    return function(a:fstr)
  endfunction
else
  function! s:___revitalizer_SID() abort
    return matchstr(expand('<sfile>'), '<SNR>\zs\d\+\ze____revitalizer_SID$')
  endfunction
  let s:___revitalizer_sid = '<SNR>' . s:___revitalizer_SID() . '_'
  function! s:___revitalizer_function___(fstr) abort
    return function(substitute(a:fstr, 's:', s:___revitalizer_sid, 'g'))
  endfunction
endif

let s:___revitalizer_functions___ = {'_vital_created': s:___revitalizer_function___('s:_vital_created'),'_vital_depends': s:___revitalizer_function___('s:_vital_depends'),'_vital_loaded': s:___revitalizer_function___('s:_vital_loaded'),'store': s:___revitalizer_function___('s:store'),'undefined': s:___revitalizer_function___('s:undefined')}

unlet! s:___revitalizer_sid
delfunction s:___revitalizer_function___

function! vital#_easymotion#Vim#Guard#import() abort
  return s:___revitalizer_functions___
endfunction
" ___Revitalizer___