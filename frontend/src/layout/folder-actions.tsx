import { ArrowUpDown, FilePlus, FolderPlus, FoldVertical } from 'lucide-react'
import { Fragment } from 'react'
import { useLocation } from 'react-router'
import { Button } from '@/components/ui/button'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuLabel,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from '@/components/ui/tooltip'
import { useCreateFolder, useCreateNote } from '@/api/queries'
import { deriveActiveFolder } from '@/lib/active-folder'
import { type SortKey, useFolderTreeState } from './folder-tree-context'

const ICON = 'size-5'
const BUTTON = 'size-10'

type SortSection = {
  label: string
  options: ReadonlyArray<{ value: SortKey; label: string }>
}

const SORT_SECTIONS: ReadonlyArray<SortSection> = [
  {
    label: 'File name',
    options: [
      { value: 'name-asc', label: 'A to Z' },
      { value: 'name-desc', label: 'Z to A' },
    ],
  },
  {
    label: 'Created time',
    options: [
      { value: 'created-desc', label: 'Newest first' },
      { value: 'created-asc', label: 'Oldest first' },
    ],
  },
  {
    label: 'Modified time',
    options: [
      { value: 'modified-desc', label: 'Newest first' },
      { value: 'modified-asc', label: 'Oldest first' },
    ],
  },
]

export default function FolderActions() {
  const { collapseAll, sort, setSort } = useFolderTreeState()
  const { pathname } = useLocation()
  const activeFolder = deriveActiveFolder(pathname)
  const targetLabel = activeFolder === '' ? 'vault root' : `"${activeFolder}"`

  const createNote = useCreateNote()
  const createFolder = useCreateFolder()

  return (
    <section
      aria-label="File actions"
      className="flex items-center justify-around border-t border-border bg-card px-4 py-0.5"
    >
      <TooltipProvider delayDuration={300}>
        <Tooltip>
          <TooltipTrigger asChild>
            <Button
              variant="ghost"
              size="icon"
              aria-label="New note"
              className={BUTTON}
              onClick={() => createNote.mutate({ folder: activeFolder })}
              disabled={createNote.isPending}
            >
              <FilePlus className={ICON} />
            </Button>
          </TooltipTrigger>
          <TooltipContent>Creates in {targetLabel}</TooltipContent>
        </Tooltip>

        <Tooltip>
          <TooltipTrigger asChild>
            <Button
              variant="ghost"
              size="icon"
              aria-label="New folder"
              className={BUTTON}
              onClick={() => createFolder.mutate({ parent: activeFolder })}
              disabled={createFolder.isPending}
            >
              <FolderPlus className={ICON} />
            </Button>
          </TooltipTrigger>
          <TooltipContent>Creates in {targetLabel}</TooltipContent>
        </Tooltip>
      </TooltipProvider>

      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button variant="ghost" size="icon" aria-label="Sort" title="Sort" className={BUTTON}>
            <ArrowUpDown className={ICON} />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="w-[min(95vw,20rem)]">
          <DropdownMenuRadioGroup value={sort} onValueChange={(v) => setSort(v as SortKey)}>
            {SORT_SECTIONS.map((section, i) => (
              // Fragment (not <section>) so Radix's roving keyboard nav across
              // DropdownMenuRadioItem siblings keeps working — wrapping them in
              // a real DOM element breaks the radio group.
              <Fragment key={section.label}>
                {i > 0 && <DropdownMenuSeparator />}
                <DropdownMenuLabel className="text-[10px] uppercase tracking-wide text-muted-foreground">
                  {section.label}
                </DropdownMenuLabel>
                {section.options.map((opt) => (
                  <DropdownMenuRadioItem key={opt.value} value={opt.value}>
                    {opt.label}
                  </DropdownMenuRadioItem>
                ))}
              </Fragment>
            ))}
          </DropdownMenuRadioGroup>
        </DropdownMenuContent>
      </DropdownMenu>
      <Button
        variant="ghost"
        size="icon"
        aria-label="Collapse all folders"
        title="Collapse all folders"
        onClick={collapseAll}
        className={BUTTON}
      >
        <FoldVertical className={ICON} />
      </Button>
    </section>
  )
}
