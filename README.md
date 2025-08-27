# dotfiles
My dotfiles using $HOME as a git clone. To initialize on new machine:
```
<install git>
cd $HOME
<move old $HOME content/config elsewhere if you want to preserve it>
git init
git branch -m main
git remote add origin https://github.com/thelandlockedalbatross/dotfiles/
git fetch origin
git checkout -b main origin/main
```


