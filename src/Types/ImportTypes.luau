--!strict
local ImportTypes = {}

export type ImportAdapter = {
	Name: string,
	Import: (Source: any) -> any,
}

return ImportTypes
